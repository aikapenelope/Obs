# Observability Platform

Sistema de observabilidad centralizado para infraestructura multi-proyecto.

## Qué incluye

| Servicio | Versión | Función |
|----------|---------|---------|
| Grafana | 13.0.1 | Dashboards + alertas |
| Loki | 3.7.2 | Logs centralizados (30 días) |
| Prometheus | v3.4.1 | Métricas (30 días) |
| Grafana Alloy | v1.16.1 | Agente de recolección |
| Bugsink | 2.1.3 | Error tracking (Sentry SDK compatible) |

## Deploy rápido

### 1. En el servidor de observabilidad:

```bash
git clone https://github.com/aikapenelope/Obs.git
cd Obs/server
chmod +x deploy.sh
./deploy.sh
```

### 2. En cada servidor que quieras monitorear:

```bash
curl -fsSL https://raw.githubusercontent.com/aikapenelope/Obs/main/agents/install.sh | bash -s -- <OBS_PLANE_IP>
```

O manualmente:
```bash
git clone https://github.com/aikapenelope/Obs.git
cd Obs/agents
chmod +x install.sh
./install.sh <OBS_PLANE_IP>
```

## Requisitos

- Ubuntu 22.04+ (o cualquier Linux con Docker)
- Docker Engine 24+
- Docker Compose v2
- 4 GB RAM mínimo para el servidor de observabilidad
- Conectividad de red entre el servidor de obs y los servidores monitoreados

## Estructura

```
Obs/
├── server/                    # Stack del servidor de observabilidad
│   ├── docker-compose.yml     # Todos los servicios
│   ├── deploy.sh              # Script de deploy (genera secrets, inicia todo)
│   ├── loki-config.yml        # Configuración de Loki
│   ├── prometheus.yml         # Configuración de Prometheus (agregar targets aquí)
│   ├── alloy-local.alloy      # Alloy local (recolecta logs del propio obs)
│   └── grafana/provisioning/  # Datasources auto-configurados
├── agents/                    # Agente para servidores monitoreados
│   └── install.sh             # Instala Alloy agent (auto-descubre containers)
└── docs/                      # Documentación
    └── FULL-STATUS.md         # Estado completo del sistema
```

## Auto-descubrimiento

Cuando Coolify (o cualquier herramienta) despliega un nuevo container Docker,
el agente Alloy lo detecta automáticamente en < 5 segundos. Los logs del nuevo
container aparecen en Grafana sin configuración adicional.

## Configuración manual necesaria

Después del deploy, estos pasos requieren acción manual:

1. **Prometheus targets** — Editar `server/prometheus.yml` para agregar endpoints `/metrics` de tus APIs
2. **Telegram alertas** — En Grafana UI: Alerting → Contact Points → Telegram
3. **Bugsink DSN** — Agregar `BUGSINK_DSN` como variable de entorno en cada proyecto

## Versiones pinneadas

Todas las imágenes Docker están pinneadas a versiones específicas.
Para actualizar: editar `docker-compose.yml`, `docker compose pull`, `docker compose up -d`.
