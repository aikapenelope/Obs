# Reporte de Robustez: Sistema de Observabilidad

> Auditoría en vivo realizada el 19 de mayo de 2026.
> Verificación SSH directa a los 4 servidores via Tailscale.

---

## Resumen Ejecutivo

El sistema de observabilidad está **operativo y funcional**. Los datos fluyen correctamente entre los 4 servidores, las alertas están configuradas, y no hay pérdida de telemetría. Sin embargo, existen puntos de fragilidad que podrían causar interrupciones bajo condiciones específicas.

| Categoría | Estado |
|-----------|--------|
| Ingestión de logs (Loki) | OK — 4 hostnames reportando |
| Ingestión de métricas (Prometheus) | OK — 20M+ samples, todos los targets UP |
| Métricas de aplicaciones | OK — Nova, Aurora, Docflow, Propi reportando |
| Alertas (Grafana → Telegram) | OK — 13 reglas activas |
| Exporters (PG + Redis) | OK — scrape cada 30s, healthy |
| Agentes Alloy | OK — v1.16.1 en los 4 servidores |
| Conectividad de red privada | OK — latencia < 5ms entre nodos |

---

## Dónde Se Puede Romper

### 1. CRÍTICO — Alloy en App Plane A se reinicia cada minuto

**Qué pasa:** El script `update-targets.sh` detecta cambios de IP en los containers de Aurora y Propi cada minuto y reinicia Alloy. Las IPs "flippean" entre `172.18.0.3` y `172.18.0.5` constantemente.

**Evidencia:**
```
04:57:01 tock4scgsws88k4okk4wo0so IP changed: 172.18.0.3 -> 172.18.0.5
04:57:02 Alloy restarted with new IPs
04:58:01 wo8w0okogc4ko80owsos44sk IP changed: 172.18.0.5 -> 172.18.0.3
04:58:01 tock4scgsws88k4okk4wo0so IP changed: 172.18.0.3 -> 172.18.0.5
04:58:02 Alloy restarted with new IPs
```

**Impacto:**
- Cada restart causa ~7-17 segundos de WAL replay donde no se envían métricas nuevas
- Se pierden ~15-30 segundos de logs por minuto durante el restart
- Los errores de "timestamp too old" del container whabi-worker se re-envían en cada restart (166 errores acumulados en logs de Loki)
- Bajo carga alta, el restart constante podría causar backpressure en el WAL y eventualmente pérdida de datos

**Causa raíz:** Dos containers (Aurora y Propi) comparten la misma IP `172.18.0.5` en momentos diferentes. Cuando uno se redespliega, el otro toma su IP y viceversa. El script detecta esto como un "cambio" y reinicia.

**Cómo se rompe completamente:** Si Coolify hace rolling updates frecuentes (múltiples deploys por hora), Alloy nunca termina de estabilizarse. Las métricas de aplicaciones tendrán gaps.

**Solución:** Agregar un debounce al script (no reiniciar si ya reinició en los últimos 2 minutos), o usar `discovery.docker` nativo de Alloy para scraping en vez de IPs hardcodeadas.

---

### 2. ALTO — Logs del whabi-worker generan errores perpetuos

**Qué pasa:** El container `bwg80gc84koc04o80cc4ccck-205711868382` (whabi-worker) lleva 6 semanas corriendo. Cada vez que Alloy se reinicia (cada minuto, ver punto #1), intenta re-enviar los logs históricos desde el 31 de marzo. Loki los rechaza porque están fuera de la ventana de retención (7 días hacia atrás).

**Impacto:**
- 166+ errores en logs de Loki por ciclo de restart
- Carga de CPU innecesaria en Loki procesando y rechazando estos pushes
- Ruido en los logs que dificulta detectar errores reales

**Cómo se rompe:** No se rompe per se, pero si se acumulan muchos containers de larga vida (>7 días), cada restart de Alloy genera una ráfaga de errores proporcional al número de containers viejos.

**Solución:** Configurar `start_position = "end"` en `loki.source.docker` para que Alloy solo envíe logs nuevos al arrancar, no los históricos. Alternativa: truncar los log files de Docker de containers viejos periódicamente.

---

### 3. ALTO — Disco del App Plane A al 63%

**Qué pasa:** El App Plane A usa 45 GB de 75 GB (63%). Es el servidor con más uso de disco de toda la plataforma.

**Evidencia:**
```
/dev/sda1  75G  45G  28G  63% /
```

Comparación:
- Obs Plane: 13% (9.4 GB)
- Data Plane: 14% (9.8 GB)
- Control Plane: 29% (11 GB)
- **App Plane A: 63% (45 GB)**

**Impacto:** El cron de limpieza (`docker image prune -a --filter "until=24h"`) corre diario a las 4 AM, pero solo limpia imágenes. Los log files de Docker, layers de build, y volúmenes huérfanos no se limpian.

**Cómo se rompe:** Si el disco llega a 90%+, Docker no puede crear nuevos containers, los deploys de Coolify fallan, y los containers existentes pueden crashear si necesitan escribir a disco. La alerta de "High Disk Usage" (>80%) daría ~2 semanas de aviso al ritmo actual.

**Solución:** Agregar `docker system prune --volumes -f --filter "until=48h"` al cron de limpieza (cuidado: esto elimina volúmenes no usados). Alternativamente, agregar solo `docker container prune -f` para limpiar containers muertos y sus logs.

---

### 4. MEDIO — Prometheus sin reglas de alerting propias

**Qué pasa:** Prometheus tiene 0 rule groups configurados. Todas las alertas están en Grafana.

**Evidencia:**
```
curl localhost:9090/api/v1/rules → Total rule groups: 0
```

**Impacto:** Si Grafana se cae (OOM, crash, disco lleno), **todas las alertas dejan de funcionar**. No hay alerting independiente.

**Cómo se rompe:** Grafana usa 124 MB de 512 MB. Si una query pesada o un dashboard con muchos paneles causa un spike de memoria, Grafana podría ser killed. En ese momento, nadie recibe alertas de que Grafana está caída (porque las alertas dependen de Grafana).

**Solución:** Mover las alertas críticas (Server Down, High Memory, High Disk) a Prometheus Alertmanager. Así, incluso si Grafana cae, las alertas de infraestructura siguen funcionando.

---

### 5. MEDIO — Single point of failure: Obs Plane

**Qué pasa:** Todo el sistema de observabilidad depende de un solo servidor (10.0.1.50). Si este servidor cae:
- Se pierden todos los logs en tránsito
- Se pierden todas las métricas en tránsito
- Las alertas dejan de funcionar
- No hay visibilidad de ningún tipo

**Cómo se rompe:**
- OOM kill de Loki (tiene 2 GB limit, si recibe un spike de logs podría saturarse)
- Disco lleno (improbable a corto plazo: 13% usado)
- Kernel panic o fallo de hardware
- Hetzner maintenance window (raro pero posible)

**Mitigación actual:**
- Backups de Hetzner habilitados (snapshots diarios)
- Los agentes Alloy tienen WAL local que buferea datos durante caídas cortas (~2 horas de buffer)

**Solución a futuro:** Para producción crítica, considerar replicar Loki/Prometheus a un segundo nodo o usar object storage (MinIO en Data Plane) como backend de Loki en vez de filesystem local.

---

### 6. MEDIO — Alloy en Control Plane tiene errores de container inexistente

**Qué pasa:** El agente Alloy en el Control Plane intenta inspeccionar un container que ya no existe (`ed8cd2f0855d`), generando errores repetidos.

**Evidencia:**
```
error="Error response from daemon: No such container: ed8cd2f0855d..."
```

**Impacto:** Ruido en logs. No afecta la recolección de otros containers, pero indica que Alloy no limpia correctamente su lista de targets cuando un container desaparece.

**Cómo se rompe:** No se rompe, pero si se acumulan muchos containers eliminados sin reiniciar Alloy, la lista de errores crece y puede afectar performance.

**Solución:** Reiniciar Alloy en el Control Plane (`cd /opt/alloy && HOSTNAME=$(hostname) docker compose restart alloy`). Esto limpia la lista de targets.

---

### 7. BAJO — Propi y Aurora comparten la misma IP:puerto en Alloy config

**Qué pasa:** Ambos scrape blocks apuntan a `172.18.0.5:3000`:

```alloy
prometheus.scrape "propi_api" {
  targets = [{ __address__ = "172.18.0.5:3000" }]
  job_name = "propi"
}
prometheus.scrape "aurora_api" {
  targets = [{ __address__ = "172.18.0.5:3000" }]
  job_name = "aurora"
}
```

**Impacto:** Solo uno de los dos está siendo scrapeado correctamente en un momento dado. El otro recibe métricas del container equivocado. Esto explica por qué `update-targets.sh` flippea las IPs constantemente.

**Cómo se rompe:** Las métricas de Propi y Aurora pueden estar mezcladas en Prometheus. Un dashboard que muestre "request rate de Propi" podría estar mostrando datos de Aurora y viceversa.

**Solución:** Verificar que cada container tiene un puerto de métricas diferente, o usar `metrics_path` diferente para distinguirlos. Actualmente ambos usan `/api/metrics` en puerto 3000.

---

## Cuán Robusta Es la Estructura

### Fortalezas

| Aspecto | Evaluación |
|---------|-----------|
| Aislamiento | Excelente — Obs Plane separado de apps, no compite por recursos |
| Auto-discovery de logs | Excelente — Cualquier container nuevo aparece en Grafana en <5s |
| Retención | Bien configurada — 30 días logs + métricas, compactor activo |
| Memory limits | Todos los containers tienen límites definidos |
| Alertas | 13 reglas cubriendo infra + DB + apps |
| Conectividad | Red privada con <5ms latencia, sin exposición a Internet |
| Versiones pinneadas | Todas las imágenes en versión específica (no `latest`) |
| Exporters dedicados | PG exporter + Redis exporter con métricas detalladas |

### Debilidades

| Aspecto | Evaluación |
|---------|-----------|
| Resiliencia | Baja — SPOF en obs-plane, sin redundancia |
| Alerting independiente | No existe — todo depende de Grafana |
| Scraping de apps | Frágil — IPs hardcodeadas + script cron que flippea |
| Dashboards | No versionados — se pierden si Grafana se destruye |
| Backups de config | Solo en este repo (Git) — el estado de Grafana (alertas, dashboards) no está en Git |

### Score de Robustez: 7/10

El sistema es **suficientemente robusto para la escala actual** (5 proyectos, ~100 usuarios). Los problemas identificados no causan pérdida de datos ni downtime, pero reducen la confiabilidad de las métricas de aplicaciones y crean un riesgo de "alerting ciego" si Grafana cae.

---

## Cómo Mejorar (Priorizado)

### Inmediato (esta semana)

| # | Acción | Esfuerzo | Impacto |
|---|--------|----------|---------|
| 1 | Agregar debounce a `update-targets.sh` (no reiniciar si <2 min desde último restart) | 10 min | Elimina restarts cada minuto |
| 2 | Reiniciar Alloy en Control Plane para limpiar errores de container fantasma | 1 min | Elimina ruido en logs |
| 3 | Agregar `docker container prune -f` al cron de limpieza del App Plane A | 5 min | Previene acumulación de disco |

### Corto plazo (próximas 2 semanas)

| # | Acción | Esfuerzo | Impacto |
|---|--------|----------|---------|
| 4 | Exportar dashboards y alertas de Grafana como JSON al repo | 1 hora | Dashboards recuperables si Grafana se pierde |
| 5 | Resolver conflicto de IP entre Propi y Aurora (puertos diferentes o discovery nativo) | 2 horas | Métricas de apps correctas y estables |
| 6 | Mover alertas críticas (Server Down, Disk, Memory) a Prometheus Alertmanager | 2 horas | Alerting independiente de Grafana |

### Medio plazo (próximo mes)

| # | Acción | Esfuerzo | Impacto |
|---|--------|----------|---------|
| 7 | Migrar scraping de apps a `discovery.docker` nativo de Alloy (eliminar `update-targets.sh`) | 4 horas | Elimina toda la fragilidad de IPs hardcodeadas |
| 8 | Configurar Loki con MinIO como object storage (en vez de filesystem local) | 4 horas | Datos de logs sobreviven pérdida del obs-plane |
| 9 | Provisioning de dashboards via archivos JSON (Grafana provisioning API) | 3 horas | Dashboards como código, reproducibles |

---

## Estado de Cada Servidor (Snapshot)

### Obs Plane (10.0.1.50)
```
Containers: 5 (all healthy, 0 restarts)
Memory:     830 MB / 8 GB (10%)
Disk:       9.4 GB / 75 GB (13%)
Uptime:     15+ hours
Issues:     Errores de timestamp en Loki (cosmético)
```

### Control Plane (10.0.1.10)
```
Containers: 10 (Coolify + Traefik + Alloy + extras)
Memory:     1.7 GB / 3.7 GB (46%)
Disk:       11 GB / 38 GB (29%)
Alloy:      OK, enviando logs y métricas
Issues:     Error de container fantasma en Alloy (cosmético)
```

### Data Plane (10.0.1.20)
```
Containers: 9 (PG + Redis + MinIO + PgBouncer + Exporters + Alloy)
Memory:     1.3 GB / 7.6 GB (17%)
Disk:       9.8 GB / 75 GB (14%)
Alloy:      OK, sin errores
PG Exporter: UP, scrapeado cada 30s
Redis Exporter: UP, scrapeado cada 30s
Issues:     Ninguno
```

### App Plane A (10.0.1.30)
```
Containers: 13 (5 proyectos + Alloy + Coolify)
Memory:     2.3 GB / 7.6 GB (30%)
Disk:       45 GB / 75 GB (63%) ⚠️
Alloy:      Reiniciándose cada minuto (ver problema #1)
Issues:     IP flipping, disco alto, whabi-worker logs viejos
```

---

## Conclusión

La estructura de observabilidad es **sólida en diseño** pero tiene **fragilidad operacional** en el App Plane A. El punto más débil es el mecanismo de scraping de métricas de aplicaciones (`update-targets.sh`), que causa restarts constantes de Alloy y potencial mezcla de métricas entre proyectos.

El sistema no va a "caerse" de forma catastrófica, pero bajo condiciones de deploys frecuentes o carga alta, la calidad de las métricas de aplicaciones se degrada. Los logs y métricas de infraestructura (CPU, RAM, disco, PostgreSQL, Redis) son completamente confiables porque no dependen del mecanismo de IPs dinámicas.

**Prioridad #1:** Resolver el flipping de IPs en el App Plane A. Todo lo demás es secundario.
