# Guía de Integración: Conectar tu App al Stack de Observabilidad

> Documento para desarrolladores y agentes de IA que necesitan configurar
> una aplicación para que envíe logs, métricas y errores al sistema centralizado.

---

## Arquitectura del Stack

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Tu Aplicación (container Docker)                    │
│                                                                           │
│  1. stdout/stderr ──────────────────────────────────────────────────┐    │
│     (JSON estructurado)                                              │    │
│                                                                      │    │
│  2. GET /api/metrics ───────────────────────────────────────────┐    │    │
│     (formato Prometheus)                                         │    │    │
│                                                                  │    │    │
│  3. POST errores ──────────────────────────────────────────┐     │    │    │
│     (@sentry/node SDK)                                      │     │    │    │
└─────────────────────────────────────────────────────────────┼─────┼────┼──┘
                                                              │     │    │
                    ┌─────────────────────────────────────────┼─────┼────┼──┐
                    │         Alloy Agent (mismo servidor)     │     │    │  │
                    │         Automático, no requiere config   │     │    │  │
                    │                                          │     │    │  │
                    │  Docker Socket ◄─────────────────────────┼─────┼────┘  │
                    │  (lee stdout de TODOS los containers)    │     │       │
                    │                                          │     │       │
                    │  Scrape /api/metrics ◄───────────────────┼─────┘       │
                    │  (cada 15s, descubre IP automáticamente) │             │
                    └──────────────────────────────────────────┼─────────────┘
                                                               │
                    ┌──────────────────────────────────────────┼─────────────┐
                    │         Obs Plane (10.0.1.50)            │             │
                    │                                          ▼             │
                    │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐    │
                    │  │   Loki   │  │Prometheus│  │     Bugsink      │    │
                    │  │  :3100   │  │  :9090   │  │     :8000        │    │
                    │  │  (logs)  │  │(métricas)│  │ (error tracking) │    │
                    │  └────┬─────┘  └────┬─────┘  └────────┬─────────┘    │
                    │       │             │                  │              │
                    │       └─────────────┼──────────────────┘              │
                    │                     │                                 │
                    │              ┌──────┴──────┐                          │
                    │              │   Grafana   │                          │
                    │              │   :3000     │                          │
                    │              │ (dashboards │                          │
                    │              │  + alertas) │                          │
                    │              └─────────────┘                          │
                    └───────────────────────────────────────────────────────┘
```

---

## Qué necesita tu app (resumen)

| Canal | Qué hace tu app | Qué hace el sistema automáticamente |
|-------|-----------------|-------------------------------------|
| **Logs** | Escribe JSON a stdout | Docker captura → Alloy envía → Loki almacena → Grafana muestra |
| **Métricas** | Expone `GET /api/metrics` en formato Prometheus | Alloy descubre tu container → scrapea cada 15s → Prometheus almacena → Grafana grafica |
| **Errores** | Usa `@sentry/node` SDK con DSN de Bugsink | SDK envía errores → Bugsink agrupa y muestra |

**Tu app NO necesita:**
- Conectarse a Loki, Prometheus, ni Grafana directamente
- Saber la IP del Obs Plane
- Configurar nada de red
- Instalar agentes

---

## Canal 1: Logs Estructurados

### Regla fundamental

**Todo lo que tu app escriba a stdout/stderr llega a Grafana automáticamente.**

Docker captura stdout → Alloy lo lee via Docker socket → lo envía a Loki → aparece en Grafana.

### Formato requerido: JSON por línea

Cada línea de stdout debe ser un objeto JSON válido. Esto permite que Loki indexe y filtre por campos.

```json
{"level":"info","ts":"2026-05-19T14:00:00.123Z","msg":"request completed","method":"GET","path":"/api/health","status":200,"duration_ms":12,"request_id":"abc-123"}
{"level":"error","ts":"2026-05-19T14:00:01.456Z","msg":"database timeout","method":"POST","path":"/api/orders","error":"connection timeout after 5000ms","request_id":"def-456"}
```

### Campos recomendados

| Campo | Tipo | Obligatorio | Descripción |
|-------|------|-------------|-------------|
| `level` | string | Sí | `debug`, `info`, `warn`, `error`, `fatal` |
| `ts` | string (ISO 8601) | Sí | Timestamp del evento |
| `msg` | string | Sí | Mensaje legible |
| `method` | string | Para requests | GET, POST, PUT, DELETE |
| `path` | string | Para requests | Ruta (patrón, no URL real) |
| `status` | number | Para requests | HTTP status code |
| `duration_ms` | number | Para requests | Duración en milisegundos |
| `request_id` | string | Recomendado | ID único para tracing |
| `error` | string | Para errores | Mensaje de error |
| `user_id` | string | Opcional | ID del usuario (sin PII) |

### Qué NO hacer

```
❌ console.log("User logged in")                    // Texto plano, no parseable
❌ console.log(`Error: ${err}`)                     // No tiene level ni timestamp
❌ console.log(JSON.stringify(hugeObject))           // Objeto enorme, llena disco
❌ Loguear passwords, tokens, emails, IPs de usuarios  // PII violation
```

### Qué SÍ hacer

```typescript
// ✅ JSON estructurado con campos útiles
logger.info({ method: "GET", path: "/api/orders", status: 200, duration_ms: 45 }, "request completed");

// ✅ Error con contexto
logger.error({ method: "POST", path: "/api/orders", error: err.message, stack: err.stack }, "request failed");

// ✅ Evento de negocio
logger.info({ event: "order_created", order_id: "abc", amount: 150.00 }, "new order");
```

### Implementación por framework

#### Node.js con Hono (como Nova)

```typescript
// src/lib/logger.ts
import pino from "pino";

export const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  // JSON output (default de pino) — perfecto para Docker/Loki
});

// En el servidor Hono:
import { logger as pinoLogger } from "./lib/logger";

app.use("*", async (c, next) => {
  const start = performance.now();
  await next();
  const duration = performance.now() - start;
  pinoLogger.info({
    method: c.req.method,
    path: c.req.routePath || c.req.path,
    status: c.res.status,
    duration_ms: Math.round(duration),
  }, "request completed");
});
```

#### Next.js (como Propi)

```typescript
// src/lib/logger.ts
import pino from "pino";

export const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  formatters: {
    level: (label) => ({ level: label }),
  },
  timestamp: pino.stdTimeFunctions.isoTime,
});

// En API routes — wrapper helper:
// src/lib/with-logging.ts
import { logger } from "./logger";
import { NextResponse } from "next/server";

export function withLogging(
  handler: (req: Request) => Promise<Response>
) {
  return async (req: Request) => {
    const start = performance.now();
    const url = new URL(req.url);
    try {
      const res = await handler(req);
      logger.info({
        method: req.method,
        path: url.pathname,
        status: res.status,
        duration_ms: Math.round(performance.now() - start),
      }, "request completed");
      return res;
    } catch (err) {
      logger.error({
        method: req.method,
        path: url.pathname,
        error: err instanceof Error ? err.message : String(err),
        duration_ms: Math.round(performance.now() - start),
      }, "request failed");
      return NextResponse.json({ error: "Internal Server Error" }, { status: 500 });
    }
  };
}

// Uso en una API route:
// src/app/api/orders/route.ts
import { withLogging } from "@/lib/with-logging";

export const GET = withLogging(async (req) => {
  // tu lógica aquí
  return NextResponse.json({ orders: [] });
});
```

#### Nuxt/Nitro (como Aurora)

```typescript
// server/utils/logger.ts
import { consola } from "consola";

// JSON output en producción
if (process.env.NODE_ENV === "production") {
  consola.options.reporters = [
    {
      log: (logObj) => {
        const json = JSON.stringify({
          level: logObj.type,
          ts: new Date().toISOString(),
          tag: logObj.tag || undefined,
          msg: logObj.args.join(" "),
        });
        process.stdout.write(json + "\n");
      },
    },
  ];
}

export const log = {
  db: consola.withTag("db"),
  api: consola.withTag("api"),
  voice: consola.withTag("voice"),
};

// server/middleware/request-log.ts
import { log } from "../utils/logger";

export default defineEventHandler((event) => {
  const start = performance.now();
  const method = getMethod(event);
  const path = getRequestURL(event).pathname;

  event.node.res.on("finish", () => {
    const duration = Math.round(performance.now() - start);
    const status = event.node.res.statusCode;
    log.api.info({ method, path, status, duration_ms: duration }, "request completed");
  });
});
```

### Cómo verificar que tus logs llegan

```bash
# 1. Verificar que tu container escribe a stdout
docker logs <tu-container> --tail 5

# 2. Verificar en Loki (desde obs-plane via Tailscale)
curl -s 'http://10.0.1.50:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name=~".*tu-container.*"}' \
  --data-urlencode 'limit=5'

# 3. En Grafana → Explore → Loki:
{service_name=~".*tu-container.*"}
```

---

## Canal 2: Métricas Prometheus

### Cómo funciona

Tu app expone un endpoint HTTP (`GET /api/metrics`) que devuelve métricas en formato Prometheus text. Alloy lo scrapea automáticamente cada 15 segundos.

### Formato de salida esperado

```
# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/api/orders",status="200"} 1523
http_requests_total{method="POST",path="/api/orders",status="201"} 89
http_requests_total{method="GET",path="/api/orders",status="500"} 3

# HELP http_request_duration_seconds HTTP request duration
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",path="/api/orders",le="0.01"} 1200
http_request_duration_seconds_bucket{method="GET",path="/api/orders",le="0.05"} 1450
http_request_duration_seconds_bucket{method="GET",path="/api/orders",le="0.1"} 1500
http_request_duration_seconds_bucket{method="GET",path="/api/orders",le="+Inf"} 1523
http_request_duration_seconds_sum{method="GET",path="/api/orders"} 45.23
http_request_duration_seconds_count{method="GET",path="/api/orders"} 1523
```

### Métricas que debes exponer (mínimo)

| Métrica | Tipo | Labels | Descripción |
|---------|------|--------|-------------|
| `http_requests_total` | Counter | method, path, status | Total de requests procesados |
| `http_request_duration_seconds` | Histogram | method, path | Duración de cada request |

### Métricas opcionales (recomendadas)

| Métrica | Tipo | Labels | Descripción |
|---------|------|--------|-------------|
| `http_errors_total` | Counter | method, path, error_type | Errores de negocio (no solo 500s) |
| `db_query_duration_seconds` | Histogram | operation, table | Duración de queries a DB |
| `external_api_duration_seconds` | Histogram | service, method | Llamadas a APIs externas |
| `queue_jobs_total` | Counter | queue, status | Jobs procesados (BullMQ) |
| `queue_job_duration_seconds` | Histogram | queue | Duración de jobs |

### Métricas default de Node.js (gratis con prom-client)

`prom-client` incluye `collectDefaultMetrics()` que expone automáticamente:

- `nodejs_heap_size_used_bytes` — memoria heap usada
- `nodejs_heap_size_total_bytes` — memoria heap total
- `nodejs_eventloop_lag_seconds` — lag del event loop (p50, p90, p99)
- `nodejs_gc_duration_seconds` — duración de garbage collection
- `nodejs_active_handles_total` — handles activos (sockets, timers)
- `process_cpu_user_seconds_total` — CPU usado

Estas métricas son críticas para detectar memory leaks y event loop blocking.

### Implementación por framework

#### Setup base (todos los frameworks)

```bash
npm install prom-client
```

```typescript
// lib/metrics.ts (o server/metrics.ts)
import { Registry, Counter, Histogram, collectDefaultMetrics } from "prom-client";

export const registry = new Registry();

// Métricas default de Node.js (heap, GC, event loop, CPU)
collectDefaultMetrics({ register: registry });

// HTTP requests counter
export const httpRequests = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "path", "status"] as const,
  registers: [registry],
});

// HTTP request duration
export const httpDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "path"] as const,
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [registry],
});
```

#### Endpoint /api/metrics

**Next.js (App Router):**
```typescript
// src/app/api/metrics/route.ts
import { registry } from "@/lib/metrics";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const metrics = await registry.metrics();
  return new Response(metrics, {
    headers: { "Content-Type": registry.contentType },
  });
}
```

**Nuxt/Nitro:**
```typescript
// server/api/metrics.get.ts
import { registry } from "~/server/utils/metrics";

export default defineEventHandler(async () => {
  const metrics = await registry.metrics();
  return metrics;
});
```

**Hono:**
```typescript
app.get("/metrics", async (c) => {
  const metrics = await registry.metrics();
  return c.text(metrics, 200, { "Content-Type": registry.contentType });
});
```

#### Middleware de instrumentación

**Next.js — wrapper para API routes:**
```typescript
// src/lib/instrumented.ts
import { httpRequests, httpDuration } from "./metrics";

export function instrumented(handler: (req: Request) => Promise<Response>) {
  return async (req: Request) => {
    const start = performance.now();
    const url = new URL(req.url);
    const method = req.method;
    const path = url.pathname.replace(/[0-9a-f-]{36}/g, "[id]"); // Normalizar UUIDs

    const res = await handler(req);

    const duration = (performance.now() - start) / 1000;
    httpRequests.inc({ method, path, status: String(res.status) });
    httpDuration.observe({ method, path }, duration);

    return res;
  };
}

// Uso:
export const GET = instrumented(async (req) => { /* ... */ });
```

**Nuxt/Nitro — middleware automático:**
```typescript
// server/middleware/metrics.ts
import { httpRequests, httpDuration } from "../utils/metrics";

export default defineEventHandler((event) => {
  const url = getRequestURL(event).pathname;
  if (url === "/api/metrics") return; // No instrumentar el propio endpoint

  const method = getMethod(event);
  const start = performance.now();

  event.node.res.on("finish", () => {
    const duration = (performance.now() - start) / 1000;
    const status = event.node.res.statusCode;
    const path = (event.context.matchedRoute?.path as string) || url;

    httpRequests.inc({ method, path, status: String(status) });
    httpDuration.observe({ method, path }, duration);
  });
});
```

### Reglas importantes para labels

1. **NUNCA uses URLs reales como label** — causa cardinality explosion
   ```
   ❌ path="/api/orders/550e8400-e29b-41d4-a716-446655440000"
   ✅ path="/api/orders/[id]"
   ```

2. **Normaliza IDs en paths:**
   ```typescript
   function normalizePath(path: string): string {
     return path
       .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "[id]")
       .replace(/\/\d+/g, "/[id]");
   }
   ```

3. **Limita el número de valores únicos por label** — máximo ~100 valores distintos por label

### Cómo Alloy descubre tu app

Alloy usa `discovery.docker` para encontrar tu container automáticamente. Busca por el label de Docker `coolify.resourceName` que Coolify asigna.

Para que Alloy scrapee tu app, necesitas:
1. Que tu container tenga el label `coolify.resourceName` (Coolify lo pone automáticamente)
2. Que tu app escuche en un puerto conocido (3000, 3001, 4000, etc.)
3. Que `/api/metrics` responda en ese puerto

Si es un proyecto nuevo, hay que agregar un bloque en la config de Alloy:

```alloy
// En /opt/alloy/config.alloy del App Plane A
discovery.relabel "mi_proyecto" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_label_coolify_resourceName"]
    regex         = "mi-proyecto-api"  // ← el resourceName en Coolify
    action        = "keep"
  }

  rule {
    source_labels = ["__meta_docker_network_ip"]
    regex         = "(.+)"
    target_label  = "__address__"
    replacement   = "$1:3000"  // ← el puerto de tu app
  }
}

prometheus.scrape "mi_proyecto_api" {
  targets         = discovery.relabel.mi_proyecto.output
  metrics_path    = "/api/metrics"  // ← la ruta de tu endpoint
  forward_to      = [prometheus.remote_write.obs_plane.receiver]
  scrape_interval = "15s"
  job_name        = "mi-proyecto"  // ← nombre en Grafana/Prometheus
}
```

### Cómo verificar que tus métricas llegan

```bash
# 1. Verificar que tu endpoint responde
curl http://<container-ip>:<port>/api/metrics | head -20

# 2. Verificar en Prometheus (desde obs-plane)
curl 'http://10.0.1.50:9090/api/v1/query?query=up{job="mi-proyecto"}'

# 3. Verificar request count
curl 'http://10.0.1.50:9090/api/v1/query?query=http_requests_total{job="mi-proyecto"}'
```

---

## Canal 3: Error Tracking (Bugsink)

### Cómo funciona

Bugsink es compatible con el SDK de Sentry. Tu app usa `@sentry/node` apuntando a Bugsink en vez de Sentry cloud.

### Setup

```bash
npm install @sentry/node
```

```typescript
// src/instrument.ts (importar al INICIO de tu entrypoint)
import * as Sentry from "@sentry/node";

if (process.env.BUGSINK_DSN) {
  Sentry.init({
    dsn: process.env.BUGSINK_DSN,
    environment: process.env.NODE_ENV || "production",
    tracesSampleRate: 0.1, // 10% de requests con traces
    beforeSend(event) {
      // Limpiar PII
      if (event.request?.headers) {
        delete event.request.headers["authorization"];
        delete event.request.headers["cookie"];
      }
      return event;
    },
  });
}
```

### Variable de entorno

Agregar en Coolify como env var del proyecto:

```
BUGSINK_DSN=http://<project-key>@10.0.1.50:8000/<project-id>
```

Los DSN por proyecto están en el doc FULL-STATUS.md o se pueden obtener en la UI de Bugsink (http://obs-plane-dev:8000).

### Qué captura automáticamente

- Excepciones no capturadas (unhandledRejection, uncaughtException)
- Errores en API routes (si usas el middleware de Sentry)
- Stack traces completos
- Breadcrumbs (últimas acciones antes del error)
- Request context (method, URL, headers)

---

## Checklist de Integración

### Para un proyecto nuevo:

```
[ ] 1. Logger estructurado (JSON a stdout)
      - Instalar pino (Node.js) o usar consola con JSON reporter (Nuxt)
      - Loguear cada request: method, path, status, duration
      - Loguear errores con stack trace

[ ] 2. Métricas Prometheus
      - Instalar prom-client
      - Crear registry con collectDefaultMetrics()
      - Definir http_requests_total (counter) y http_request_duration_seconds (histogram)
      - Crear endpoint GET /api/metrics
      - Crear middleware que llame .inc() y .observe() en cada request
      - Normalizar paths (reemplazar UUIDs con [id])

[ ] 3. Error tracking (opcional pero recomendado)
      - Instalar @sentry/node
      - Configurar con BUGSINK_DSN
      - Importar instrument.ts al inicio del entrypoint

[ ] 4. Configurar Alloy (una vez, en el servidor)
      - Agregar discovery.relabel block con el coolify.resourceName
      - Agregar prometheus.scrape block con el puerto y metrics_path
      - Reiniciar Alloy: cd /opt/alloy && HOSTNAME=$(hostname) docker compose restart alloy

[ ] 5. Verificar
      - docker logs <container> muestra JSON
      - curl /api/metrics devuelve métricas Prometheus
      - Grafana → Per-Project Health muestra el nuevo proyecto
      - Grafana → Application Logs muestra logs del nuevo container
```

### Para un proyecto existente que no tiene logs:

```
[ ] 1. Agregar logger (pino o consola con JSON)
[ ] 2. Agregar middleware de request logging
[ ] 3. Verificar que stdout tiene output JSON
[ ] 4. Esperar tráfico → logs aparecen en Grafana
```

### Para un proyecto existente que tiene métricas definidas pero no instrumentadas:

```
[ ] 1. Agregar middleware que llame .inc() y .observe()
[ ] 2. Verificar: curl /api/metrics muestra counters > 0
[ ] 3. Esperar 15s → métricas aparecen en Prometheus
```

---

## Troubleshooting

### "No Data" en Grafana Application Logs

| Causa | Diagnóstico | Solución |
|-------|-------------|----------|
| Container no escribe a stdout | `docker logs <container> --tail 5` está vacío | Agregar logger |
| Container silencioso (sin tráfico) | Logs solo aparecen cuando hay requests | Normal — enviar un request de prueba |
| Alloy no está tailing el container | `docker logs alloy-agent` muestra errores | Reiniciar Alloy |
| Loki rechaza logs (timestamp viejo) | Logs de Alloy muestran "timestamp too old" | Reiniciar Alloy (limpia WAL) |

### Métricas en 0 o "No Data" en Per-Project Health

| Causa | Diagnóstico | Solución |
|-------|-------------|----------|
| Endpoint no responde | `curl http://<ip>:<port>/api/metrics` falla | Verificar que la ruta existe y el puerto es correcto |
| Métricas definidas pero no instrumentadas | El endpoint responde pero counters están en 0 | Agregar middleware de instrumentación |
| Alloy no descubre el container | `up{job="mi-proyecto"}` no existe en Prometheus | Verificar coolify.resourceName y agregar bloque en Alloy |
| Container se redeployó | IP cambió | Alloy lo detecta en ≤60s automáticamente |

### Errores no llegan a Bugsink

| Causa | Diagnóstico | Solución |
|-------|-------------|----------|
| DSN no configurado | `echo $BUGSINK_DSN` vacío | Agregar env var en Coolify |
| Bugsink no accesible | `curl http://10.0.1.50:8000` falla | Verificar red privada |
| SDK no inicializado | No hay import de instrument.ts | Importar al inicio del entrypoint |

---

## Referencia Rápida

### Puertos y direcciones

| Servicio | Dirección | Acceso |
|----------|-----------|--------|
| Loki | 10.0.1.50:3100 | Solo Alloy (tu app no se conecta) |
| Prometheus | 10.0.1.50:9090 | Solo Alloy (tu app no se conecta) |
| Grafana | obs-plane-dev:3000 (Tailscale) | Browser |
| Bugsink | 10.0.1.50:8000 | Tu app via BUGSINK_DSN |

### Labels de Docker que usa Alloy

| Label | Ejemplo | Quién lo pone |
|-------|---------|---------------|
| `coolify.resourceName` | `nova-api`, `propi-main` | Coolify (automático) |
| `coolify.projectName` | `nova`, `propi` | Coolify (automático) |
| `coolify.serviceName` | `nova-api`, `propi-main` | Coolify (automático) |

### Proyectos actuales configurados

| Proyecto | resourceName | Puerto | metrics_path | job en Prometheus |
|----------|-------------|--------|--------------|-------------------|
| Nova API | `nova-api` | 3001 | `/metrics` | `nova-api` |
| Propi | `propi-main` | 3000 | `/api/metrics` | `propi` |
| Aurora | `aurora-main` | 3000 | `/api/metrics` | `aurora` |
| Docflow API | `docflow-api` | 4000 | `/api/metrics` | `docflow` |

### Dependencias npm

```json
{
  "prom-client": "^15.1.3",
  "pino": "^9.0.0",
  "@sentry/node": "^8.0.0"
}
```
