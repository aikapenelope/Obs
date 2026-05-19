# Estado Completo del Sistema de Observabilidad

> Última actualización: Mayo 19, 2026

---

## Infraestructura Desplegada

| Servidor | IP Pública | IP Privada | IP Tailscale | Specs |
|----------|-----------|------------|--------------|-------|
| Control Plane | 89.167.75.19 | 10.0.1.10 | 100.66.177.9 | CX23, 4GB RAM |
| Data Plane | 95.216.195.185 | 10.0.1.20 | 100.103.72.91 | CX33, 8GB RAM |
| App Plane A | 95.216.216.149 | 10.0.1.30 | 100.90.211.85 | CX33, 8GB RAM |
| Obs Plane | 89.167.47.109 | 10.0.1.50 | 100.112.10.21 | CX33, 8GB RAM |

## Servicios de Observabilidad

| Servicio | Puerto | Estado | Acceso |
|----------|--------|--------|--------|
| Grafana 13.0.1 | :3000 | Healthy | http://100.112.10.21:3000 |
| Loki 3.7.2 | :3100 | Healthy | Solo red interna |
| Prometheus v3.4.1 | :9090 | Healthy | http://100.112.10.21:9090 |
| Bugsink 2.1.3 | :8000 | Healthy | http://100.112.10.21:8000 |
| Alloy v1.16.1 | :4317 | Running | Solo red interna |

## Agentes Instalados

| Servidor | Alloy Agent | Logs → Loki | Metrics → Prometheus |
|----------|-------------|-------------|---------------------|
| Control Plane | v1.16.1 | ✅ | ✅ |
| Data Plane | v1.16.1 | ✅ | ✅ |
| App Plane A | v1.16.1 | ✅ | ✅ |
| Obs Plane | v1.16.1 (local) | ✅ | ✅ |

## Exporters

| Exporter | Servidor | Puerto | Métricas |
|----------|----------|--------|----------|
| PostgreSQL Exporter v0.16.0 | Data Plane | :9187 | 1367 métricas |
| Redis Exporter v1.67.0 | Data Plane | :9121 | 1592 métricas |

## Dashboards en Grafana

| Dashboard | Contenido |
|-----------|-----------|
| Platform Overview (Home) | CPU, RAM, Disco, Network, Errores recientes |
| Application Logs | Logs filtrables por service_name y hostname |
| PostgreSQL | Conexiones, cache hit, txn/s, DB size |
| Redis | Memory, clients, commands/s, hit rate |

## Alert Rules (13 activas → Telegram)

### Infrastructure
| Alerta | Condición | Severidad | Duración |
|--------|-----------|-----------|----------|
| High Memory Usage | RAM > 85% | warning | 5 min |
| High Disk Usage | Disco > 80% | warning | 10 min |
| CPU High | CPU > 80% | warning | 10 min |
| Server Down | Target unreachable | critical | 2 min |
| Swap In Use | Swap > 100 MB | warning | 5 min |

### Database
| Alerta | Condición | Severidad | Duración |
|--------|-----------|-----------|----------|
| PG Connections High | > 150 de 200 | warning | 5 min |
| PG Deadlocks | Cualquiera | warning | 1 min |
| PG Rollback Rate High | > 5% | warning | 10 min |
| Redis Memory High | > 80% de 1GB | warning | 5 min |
| Redis Rejected Connections | Cualquiera | critical | 1 min |

### Application
| Alerta | Condición | Severidad | Duración |
|--------|-----------|-----------|----------|
| High Error Rate | > 20 errores en 5 min | critical | 5 min |
| OOM Kill Detected | Cualquiera | critical | Instant |
| DB Connection Refused | > 3 en 5 min | critical | 2 min |
| Redis Connection Issues | > 5 timeouts en 5 min | warning | 5 min |

## Bugsink (Error Tracking)

| Proyecto | ID | DSN |
|----------|-----|-----|
| Nova | 1 | http://ebcc665f-a4e9-47e3-ae8a-37f6c06eb5ed@10.0.1.50:8000/1 |
| Whabi | 2 | http://c21eaca5-f304-4341-8b6e-edaf01652f72@10.0.1.50:8000/2 |
| Docflow | 3 | http://f6273218-a3b5-40ad-9d61-42e347fd32d5@10.0.1.50:8000/3 |
| Aurora | 4 | http://a3e32d5f-535c-4f35-a22e-8cf7394f423c@10.0.1.50:8000/4 |
| Propi | 5 | http://94f57ecb-20c4-43f0-b0a9-f1d22e77d4fb@10.0.1.50:8000/5 |

## Telegram Alerting

| Config | Valor |
|--------|-------|
| Bot | @Graffannabot |
| Chat ID | 563825119 (DM a @Angbhg) |
| Notification Policy | Todas las alertas → Telegram |
| Group Wait | 30s |
| Repeat Interval | 4h |

## Limpieza Automática

| Servidor | Mecanismo | Schedule |
|----------|-----------|----------|
| App Plane A | Docker image prune + builder prune | Diario 4 AM |
| Loki | Compactor (retention 30d) | Cada 10 min |
| Prometheus | TSDB retention (30d / 20GB) | Automático |
| Docker logs (todos) | json-file 10MB × 3 files | Automático |

## Retención de Datos

| Dato | Retención | Limpieza |
|------|-----------|----------|
| Logs (Loki) | 30 días | Automática |
| Métricas (Prometheus) | 30 días o 20 GB | Automática |
| Errores (Bugsink) | Indefinida | Manual (pesan poco) |
| Docker images (App Plane) | 24 horas | Cron diario |

## Costos

| Servidor | Tipo | Costo/mes |
|----------|------|-----------|
| Obs Plane | CX33 | €6.99 |
| **Total observabilidad** | | **€6.99/mes** |

## Lo que Falta (Pendiente)

| # | Item | Prioridad | Quién |
|---|------|-----------|-------|
| 1 | Merge PR #351 (prom-client) + deploy | Media | Angel (merge) + Coolify (deploy) |
| 2 | Configurar Prometheus scrape para Nova /metrics | Media | Neo (después de #1) |
| 3 | Custom Container Names en Coolify + redeploy | Baja | Angel |
| 4 | Mover alertas a grupo Telegram | Baja | Angel (re-agregar bot) |
| 5 | Replicar prom-client en otros proyectos | Baja | Prompt maestro |
| 6 | Dashboard por proyecto | Baja | Neo (después de #5) |
| 7 | Cerrar SSH del Obs Plane | Baja | Neo (pulumi up) |
| 8 | Resolver ToolJet "database not found" | Baja | Angel |

## Cómo Reproducir en Otro VPS

```bash
# 1. En el nuevo VPS (Ubuntu 22.04+, Docker instalado):
git clone https://github.com/aikapenelope/Obs.git
cd Obs/server
./deploy.sh

# 2. En cada servidor a monitorear:
cd Obs/agents
./install.sh <IP_DEL_NUEVO_OBS_PLANE>

# 3. Configurar manualmente:
#    - Editar prometheus.yml con los targets
#    - Configurar Telegram en Grafana UI
#    - Agregar BUGSINK_DSN a las apps
```
