# Roadmap de Observabilidad — Plan por Sprints

> Plan incremental para llevar el sistema de observabilidad de 7/10 a 10/10.
> Cada sprint es independiente y genera un PR mergeable.
> Prioridad: máximo valor con mínimo riesgo en cada paso.

---

## Sprint 1 — Higiene y Correcciones (1-2 días)

**Objetivo:** Eliminar falsos positivos, liberar disco, y dejar el sistema limpio.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 1.1 | Corregir alerta "High Error Rate" (DatasourceError) | Obs Plane (Grafana) | Ninguno | 10 min |
| 1.2 | Agregar `docker container prune -f` al cron de limpieza | App Plane A | Bajo | 5 min |
| 1.3 | Limpiar imágenes Docker huérfanas manualmente | App Plane A | Bajo | 5 min |
| 1.4 | Verificar que la alerta de disco (>80%) funciona | Obs Plane (Grafana) | Ninguno | 10 min |
| 1.5 | Agregar alerta `absent(up{job="X"})` por cada app | Obs Plane (Grafana) | Ninguno | 15 min |

**Entregable:** PR con documentación de las correcciones aplicadas.

**Detalle 1.1:** La alerta "High Error Rate" usa una query que devuelve time series en vez de un valor reducido. Hay que cambiarla para usar un reducer (`last()` o `sum()`).

**Detalle 1.5:** Si un app deja de reportar métricas (container muerto, Alloy caído), actualmente no hay alerta. `absent(up{job="nova-api"})` dispara si Nova desaparece.

---

## Sprint 2 — Métricas de Traefik + Dashboard Per-Project (2-3 días)

**Objetivo:** Visibilidad del tráfico HTTP real que entra a la plataforma y latencia por proyecto.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 2.1 | Habilitar métricas Prometheus en Traefik | Control Plane | Bajo | 30 min |
| 2.2 | Agregar scrape de Traefik en Alloy del Control Plane | Control Plane | Bajo | 15 min |
| 2.3 | Crear dashboard "Traffic Overview" en Grafana | Obs Plane | Ninguno | 1 hora |
| 2.4 | Crear dashboard "Per-Project Health" en Grafana | Obs Plane | Ninguno | 2 horas |
| 2.5 | Exportar dashboards como JSON al repo | Obs Plane | Ninguno | 30 min |

**Entregable:** PR con configs de Traefik, config de Alloy actualizada, y JSONs de dashboards.

**Dashboard "Traffic Overview":**
- Requests/sec totales por dominio
- Status codes (2xx, 4xx, 5xx) por dominio
- Latencia p50/p95/p99 por ruta
- Certificados SSL: días hasta expiración
- Top 10 rutas más lentas

**Dashboard "Per-Project Health":**
- Request rate por app (Nova, Propi, Aurora, Docflow)
- Error rate (% de 5xx) por app
- Latencia p95 por app
- Requests activas (in-flight)
- Últimos errores de Loki filtrados por app

**Cómo habilitar métricas en Traefik:**
Traefik ya corre en el Control Plane via Coolify. Necesita agregar en su config:
```yaml
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
```
O via labels de Docker si Coolify lo permite.

---

## Sprint 3 — Alertmanager Independiente + Dashboard Provisioning (2-3 días)

**Objetivo:** Que las alertas críticas funcionen incluso si Grafana se cae. Dashboards como código.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 3.1 | Agregar Alertmanager al docker-compose del Obs Plane | Obs Plane | Bajo | 30 min |
| 3.2 | Configurar Alertmanager → Telegram | Obs Plane | Bajo | 30 min |
| 3.3 | Crear recording rules en Prometheus para alertas críticas | Obs Plane | Bajo | 1 hora |
| 3.4 | Mover alertas Server Down, High Memory, High Disk a Prometheus | Obs Plane | Bajo | 1 hora |
| 3.5 | Configurar Grafana dashboard provisioning via JSON files | Obs Plane | Bajo | 1 hora |
| 3.6 | Exportar todos los dashboards existentes al repo | Obs Plane | Ninguno | 30 min |

**Entregable:** PR con Alertmanager config, recording rules, y directorio `grafana/dashboards/` con JSONs.

**Por qué Alertmanager separado:**
Actualmente si Grafana se cae (OOM, crash), todas las alertas dejan de funcionar. Con Alertmanager en Prometheus, las alertas de infraestructura (Server Down, Disk Full, Memory High) siguen disparando a Telegram independientemente de Grafana.

**Estructura de provisioning:**
```
server/
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasources.yml
│       └── dashboards/
│           ├── dashboards.yml          ← provider config
│           ├── platform-overview.json
│           ├── application-logs.json
│           ├── postgresql.json
│           ├── redis.json
│           ├── traffic-overview.json
│           └── per-project-health.json
```

---

## Sprint 4 — MinIO, PgBouncer, Container Metrics (2-3 días)

**Objetivo:** Visibilidad completa del Data Plane y recursos por container.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 4.1 | Habilitar métricas de MinIO (endpoint nativo) | Data Plane | Bajo | 15 min |
| 4.2 | Agregar scrape de MinIO en Prometheus | Obs Plane | Bajo | 10 min |
| 4.3 | Agregar PgBouncer exporter o scrape directo | Data Plane | Bajo | 30 min |
| 4.4 | Crear dashboard "Data Plane" (PG + Redis + MinIO + PgBouncer) | Obs Plane | Ninguno | 2 horas |
| 4.5 | Agregar métricas de containers (CPU/RAM por container) via Alloy | App Plane A | Bajo | 30 min |
| 4.6 | Crear dashboard "Container Resources" | Obs Plane | Ninguno | 1 hora |

**Entregable:** PR con configs de exporters, scrape targets, y dashboards JSON.

**Dashboard "Data Plane":**
- PostgreSQL: conexiones por DB, cache hit ratio, transacciones/sec, slow queries
- Redis: memoria, commands/sec, clients, hit rate, keyspace
- MinIO: storage por bucket, requests/sec, errores
- PgBouncer: pool usage, wait time, client queue

**Dashboard "Container Resources":**
- CPU por container (top 10)
- RAM por container (top 10)
- Network I/O por container
- Restart count por container
- Container uptime

**Métricas de containers via Alloy:**
Alloy ya tiene acceso al Docker socket. Agregar:
```alloy
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

prometheus.scrape "docker_metrics" {
  targets    = discovery.docker.containers.targets
  forward_to = [prometheus.remote_write.obs_plane.receiver]
  // Alloy expone métricas de containers descubiertos automáticamente
}
```

---

## Sprint 5 — Synthetic Monitoring + Business Metrics (2-3 días)

**Objetivo:** Verificar disponibilidad desde afuera y métricas de negocio.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 5.1 | Configurar Uptime Kuma con checks HTTP para cada dominio | Control Plane | Ninguno | 30 min |
| 5.2 | Exponer métricas de Uptime Kuma a Prometheus | Control Plane | Bajo | 15 min |
| 5.3 | Crear dashboard "External Availability" | Obs Plane | Ninguno | 1 hora |
| 5.4 | Agregar métricas de negocio custom en apps (requests/hora, usuarios activos) | App code | Medio | Variable |
| 5.5 | Crear dashboard "Business Overview" | Obs Plane | Ninguno | 1 hora |

**Entregable:** PR con config de Uptime Kuma, dashboard JSON, y guía para agregar métricas de negocio.

**Dashboard "External Availability":**
- Uptime % por dominio (24h, 7d, 30d)
- Response time desde afuera por dominio
- Certificados SSL: días hasta expiración
- Incidentes recientes (timeline)

**Dashboard "Business Overview":**
- Nova: ventas/hora, usuarios activos
- Whabi: mensajes/hora, conversaciones activas
- Docflow: citas/día, pacientes activos
- Aurora: comandos de voz/hora
- Propi: propiedades listadas, leads/día

---

## Sprint 6 — Hardening y Redundancia (3-5 días)

**Objetivo:** Resiliencia ante fallos y seguridad completa.

| # | Tarea | Servidor | Riesgo | Tiempo |
|---|-------|----------|--------|--------|
| 6.1 | Cerrar SSH público del Obs Plane (solo Tailscale) | Obs Plane (Pulumi) | Bajo | 15 min |
| 6.2 | Configurar Loki con MinIO como backend (en vez de filesystem) | Obs Plane + Data Plane | Medio | 3 horas |
| 6.3 | Backup automático de Grafana (dashboards + alertas) | Obs Plane | Bajo | 1 hora |
| 6.4 | Agregar protección al servidor obs-plane en Pulumi | IaC | Bajo | 15 min |
| 6.5 | Sincronizar cloud-init del IaC con la config real de producción | IaC | Bajo | 1 hora |
| 6.6 | Documentar runbook de disaster recovery | Docs | Ninguno | 2 horas |

**Entregable:** PR en platform-infra (Pulumi) + PR en Obs (configs + docs).

---

## Resumen Visual

```
Sprint 1 (Higiene)          ████░░░░░░  Esfuerzo: Bajo
Sprint 2 (Traefik+Dash)    ██████░░░░  Esfuerzo: Medio
Sprint 3 (Alertmanager)    ██████░░░░  Esfuerzo: Medio
Sprint 4 (Data Plane)      ██████░░░░  Esfuerzo: Medio
Sprint 5 (Synthetic)       █████░░░░░  Esfuerzo: Medio
Sprint 6 (Hardening)       ████████░░  Esfuerzo: Alto

Score esperado:
  Actual:           7/10
  Post Sprint 1-2:  8/10
  Post Sprint 3-4:  9/10
  Post Sprint 5-6:  10/10
```

---

## Orden de Ejecución

Cada sprint es un PR independiente. Se pueden hacer en paralelo si no tocan el mismo servidor, pero se recomienda secuencial para minimizar riesgo:

1. **Sprint 1** primero (limpia el terreno, elimina ruido)
2. **Sprint 2** segundo (mayor valor visible: dashboards nuevos)
3. **Sprint 3** tercero (robustez del alerting)
4. **Sprint 4** cuarto (completar visibilidad del data plane)
5. **Sprint 5** quinto (visibilidad externa)
6. **Sprint 6** último (hardening, requiere más cuidado)

---

## Notas

- Cada sprint se implementa, se verifica en producción, y se documenta antes de pasar al siguiente.
- Los dashboards se exportan como JSON y se versionan en este repo.
- Ningún sprint requiere downtime de aplicaciones.
- Los cambios en servidores se hacen via Tailscale SSH, no requieren Pulumi (excepto Sprint 6).
