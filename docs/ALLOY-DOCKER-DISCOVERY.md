# Alloy: Docker Discovery para Métricas de Aplicaciones

> Solución de producción para scrapear métricas de containers Docker
> cuyas IPs cambian en cada redeploy de Coolify.

---

## Problema

Los containers Docker en Coolify reciben IPs internas efímeras (172.18.0.x) que cambian
con cada redeploy. Alloy necesita esas IPs para scrapear los endpoints `/metrics` de cada app.

### Solución anterior (deprecada): `update-targets.sh`

Un cron script que corría cada minuto:
1. Buscaba containers por prefijo de nombre (Coolify ID)
2. Obtenía la IP actual via `docker inspect`
3. Editaba el config de Alloy con `sed`
4. Reiniciaba Alloy si alguna IP cambió

**Problemas:**
- Reiniciaba Alloy cada minuto cuando dos containers compartían el mismo puerto
- El `sed` reemplazaba globalmente, causando que IPs de un proyecto apuntaran al container equivocado
- Cada restart causaba 7-17 segundos de WAL replay sin envío de métricas
- Logs históricos se re-enviaban en cada restart, generando errores en Loki

### Solución actual: `discovery.docker` nativo de Alloy

Alloy tiene un componente built-in (`discovery.docker`) que:
1. Se conecta al Docker socket
2. Lista todos los containers cada 60 segundos (configurable via `refresh_interval`)
3. Expone meta-labels con la IP, nombre, labels Docker, etc.
4. Permite filtrar containers por labels usando `discovery.relabel`

**Ventajas:**
- Zero restarts: Alloy detecta containers nuevos sin reiniciarse
- Zero scripts externos: no hay cron, no hay sed, no hay race conditions
- Correcto por diseño: cada container tiene su propia IP en los meta-labels
- Estándar de la industria: es el approach oficial de Grafana Labs

---

## Cómo Funciona

### Arquitectura

```
Docker Socket (/var/run/docker.sock)
       │
       ▼
discovery.docker "containers"
       │
       ├── Detecta TODOS los containers (cada 60s)
       │   Expone: __meta_docker_network_ip, __meta_docker_container_label_*
       │
       ▼
discovery.relabel "nova_api"          ← Filtra por coolify.resourceName = "nova-api"
discovery.relabel "propi"             ← Filtra por coolify.resourceName = "propi-main"
discovery.relabel "aurora"            ← Filtra por coolify.resourceName = "aurora-main"
discovery.relabel "docflow"           ← Filtra por coolify.resourceName = "docflow-api"
       │
       │   Cada relabel:
       │   1. keep solo el container que matchea el label
       │   2. Construye __address__ = <IP>:<puerto>
       │
       ▼
prometheus.scrape "nova_api"          ← Scrapea /metrics en la IP descubierta
prometheus.scrape "propi_api"         ← Scrapea /api/metrics
prometheus.scrape "aurora_api"        ← Scrapea /api/metrics
prometheus.scrape "docflow_api"       ← Scrapea /api/metrics
       │
       ▼
prometheus.remote_write "obs_plane"   ← Envía a Prometheus en 10.0.1.50:9090
```

### Labels de Coolify usados

Coolify asigna estos labels a cada container:

| Label | Ejemplo | Estabilidad |
|-------|---------|-------------|
| `coolify.resourceName` | `nova-api` | Estable (definido por el usuario en Coolify UI) |
| `coolify.name` | `w0o0k4owsw8s0csscocwwk0s` | Estable (ID interno de Coolify, nunca cambia) |
| `coolify.projectName` | `nova` | Estable (nombre del proyecto en Coolify) |
| `coolify.serviceName` | `nova-api` | Estable (nombre del servicio) |

Usamos `coolify.resourceName` porque es legible y lo define el usuario.

En los meta-labels de Alloy, los puntos se convierten a underscores:
- `coolify.resourceName` → `__meta_docker_container_label_coolify_resourceName`

### Timing de detección

| Evento | Tiempo de detección |
|--------|-------------------|
| Container nuevo (deploy) | ≤ 60s (refresh_interval) + 15s (scrape_interval) = **≤ 75s** |
| Container eliminado (redeploy) | ≤ 60s (desaparece del discovery) |
| IP cambia (restart) | ≤ 60s (nueva IP en meta-labels) |

---

## Configuración Completa

Archivo: `/opt/alloy/config.alloy` en App Plane A

```alloy
// Docker Discovery (compartido por logs y métricas)
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

// --- Logs (auto-discovery de TODOS los containers) ---
discovery.relabel "log_targets" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container_name"
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "service_name"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.log_targets.output
  forward_to = [loki.process.pipeline.receiver]
}

// --- Métricas de sistema ---
prometheus.exporter.unix "node" {
  set_collectors = ["cpu", "meminfo", "diskstats", "filesystem", "loadavg", "netdev"]
}

prometheus.scrape "node_metrics" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.obs_plane.receiver]
  scrape_interval = "15s"
}

// --- Métricas de apps (discovery por label) ---
discovery.relabel "<PROJECT>" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_label_coolify_resourceName"]
    regex         = "<RESOURCE_NAME>"
    action        = "keep"
  }

  rule {
    source_labels = ["__meta_docker_network_ip"]
    regex         = "(.+)"
    target_label  = "__address__"
    replacement   = "$1:<PORT>"
  }
}

prometheus.scrape "<PROJECT>_api" {
  targets         = discovery.relabel.<PROJECT>.output
  metrics_path    = "<METRICS_PATH>"
  forward_to      = [prometheus.remote_write.obs_plane.receiver]
  scrape_interval = "15s"
  job_name        = "<JOB_NAME>"
}
```

---

## Agregar un Nuevo Proyecto

Cuando un nuevo proyecto con prom-client se despliega en Coolify:

1. **Verificar el resourceName en Coolify:**
   ```bash
   docker inspect <container> --format={{.Config.Labels}} | tr " " "\n" | grep coolify.resource
   ```

2. **Agregar un bloque discovery.relabel + prometheus.scrape** al config:
   ```alloy
   discovery.relabel "nuevo_proyecto" {
     targets = discovery.docker.containers.targets
     rule {
       source_labels = ["__meta_docker_container_label_coolify_resourceName"]
       regex         = "nuevo-proyecto-api"
       action        = "keep"
     }
     rule {
       source_labels = ["__meta_docker_network_ip"]
       regex         = "(.+)"
       target_label  = "__address__"
       replacement   = "$1:3000"
     }
   }

   prometheus.scrape "nuevo_proyecto_api" {
     targets         = discovery.relabel.nuevo_proyecto.output
     metrics_path    = "/metrics"
     forward_to      = [prometheus.remote_write.obs_plane.receiver]
     scrape_interval = "15s"
     job_name        = "nuevo-proyecto"
   }
   ```

3. **Reiniciar Alloy:**
   ```bash
   cd /opt/alloy && HOSTNAME=$(hostname) docker compose restart alloy
   ```

4. **Verificar en Prometheus** (esperar ~75 segundos):
   ```bash
   curl 'http://10.0.1.50:9090/api/v1/query?query=up{job="nuevo-proyecto"}'
   ```

---

## Qué Se Puede Romper

| Escenario | Impacto | Probabilidad | Mitigación |
|-----------|---------|--------------|------------|
| Coolify cambia el label `coolify.resourceName` | Métricas de esa app dejan de llegar | Muy baja (es un label estable desde Coolify v4) | Monitorear con alerta `absent(up{job="X"})` |
| Docker socket inaccesible | Todas las métricas y logs se pierden | Muy baja (requiere fallo de Docker daemon) | Alloy se reinicia automáticamente (restart: unless-stopped) |
| Container sin red (network_mode: none) | `__meta_docker_network_ip` vacío, no se scrapea | No aplica (Coolify siempre usa red bridge) | N/A |
| Alloy se actualiza y cambia API de discovery | Config inválida, Alloy no arranca | Baja (API es estable desde v1.0) | Pinnear versión de Alloy, testear antes de upgrade |
| Coolify actualiza y cambia formato de labels | Filtro no matchea, métricas se pierden | Baja (labels son parte del API público de Coolify) | Verificar labels después de cada upgrade de Coolify |
| Múltiples containers con mismo resourceName | Alloy scrapea ambos, métricas duplicadas | Posible durante rolling updates | Coolify elimina el viejo antes de crear el nuevo (default) |

---

## Diferencias con el Approach Anterior

| Aspecto | Cron + sed (antes) | discovery.docker (ahora) |
|---------|-------------------|--------------------------|
| Detección de IP nueva | 60s (cron) + restart | 60s (refresh) sin restart |
| Restart de Alloy | Cada vez que una IP cambia | Nunca (hot-reload de targets) |
| Pérdida de métricas | 7-17s por restart | 0s |
| Mezcla de métricas | Posible (sed global) | Imposible (filtro por label) |
| Mantenimiento | Editar script + config | Solo editar config |
| Estándar OSS | No (script custom) | Sí (componente oficial de Alloy) |
| Sobrevive upgrade de Alloy | Sí (script externo) | Sí (config nativa) |

---

## Verificación Post-Deploy

Después de cualquier cambio en la config de Alloy o upgrade de Coolify:

```bash
# 1. Verificar que Alloy está corriendo
docker ps --filter name=alloy

# 2. Verificar que no hay errores
docker logs alloy-agent --tail 20 2>&1 | grep -i error

# 3. Verificar targets en Prometheus (desde obs-plane)
curl -s 'http://10.0.1.50:9090/api/v1/query?query=up{job=~"nova.*|propi.*|aurora.*|docflow.*"}' | \
  python3 -c 'import sys,json; [print(f"  {r[\"metric\"][\"job\"]}: up={r[\"value\"][1]}") for r in json.load(sys.stdin)["data"]["result"]]'

# 4. Verificar que el cron viejo NO está activo
ls /etc/cron.d/alloy-targets 2>/dev/null && echo "WARNING: cron viejo activo!" || echo "OK: cron deshabilitado"
```

---

## Referencias

- [Alloy discovery.docker docs](https://grafana.com/docs/alloy/latest/reference/components/discovery/discovery.docker/)
- [Alloy discovery.relabel docs](https://grafana.com/docs/alloy/latest/reference/components/discovery/discovery.relabel/)
- [Coolify container labels](https://coolify.io/docs) — `coolify.resourceName` es estable desde v4.0
- [Prometheus relabeling](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)
