# Alloy Agent: Auto-Discovery and Metrics Scraping

## Problem

Docker container IPs are ephemeral — they change on every redeploy. If Alloy has
hardcoded IPs for scraping `/metrics` endpoints, it breaks after every Coolify deploy.

## Why Other Solutions Don't Work

| Approach | Why it fails |
|----------|-------------|
| **Port Mappings in Coolify** | Breaks Rolling Updates (Coolify docs: "the new container cannot bind to the same port during the update process") |
| **Custom Container Names** | Breaks Rolling Updates (Coolify docs: "Rolling updates require the use of the default container naming convention") |
| **Alloy in `coolify` Docker network** | Incompatible with `network_mode: host` (required for system metrics via /proc and /sys) |
| **Docker labels for discovery** | Coolify doesn't expose a way to add custom labels to containers easily |

## Solution: Cron-based IP Auto-Update

A script (`update-targets.sh`) runs every minute and:
1. Finds containers by their **stable name prefix** (Coolify prefixes never change between deploys)
2. Gets the current IP via `docker inspect`
3. Compares with the IP in Alloy's config
4. Only if changed: updates config + restarts Alloy (< 2 seconds downtime in metrics collection)

### Why container name prefixes are stable

Coolify generates container names like: `w0o0k4owsw8s0csscocwwk0s-024508918717`

The prefix (`w0o0k4owsw8s0csscocwwk0s`) is derived from the Coolify resource ID and **never changes**.
The suffix (`024508918717`) is the deployment timestamp and changes on every deploy.

The script uses `docker ps --filter "name=PREFIX"` which matches any container starting with that prefix.

## Architecture

```
App Plane A (10.0.1.30, 8 GB RAM)
├── alloy-agent (network_mode: host, 128 MB limit)
│   ├── Reads Docker socket → sends logs to Loki (10.0.1.50:3100)
│   ├── Reads /proc, /sys → sends system metrics to Prometheus (10.0.1.50:9090)
│   └── Scrapes container IPs → sends app metrics to Prometheus
│
├── Cron: /opt/alloy/update-targets.sh (every 1 min)
│   └── Updates Alloy config if container IPs changed
│
├── Nova API container (172.18.0.x:3001/metrics)
├── Propi container (172.18.0.x:3000/api/metrics)
├── Aurora container (172.18.0.x:3000/api/metrics)
├── DocFlow API container (172.18.0.x:4000/api/metrics/metrics)
└── ... other containers
```

## Adding a New Project

When a new project with prom-client is deployed:

1. **Add a scrape block** to `/opt/alloy/config.alloy`:
```alloy
prometheus.scrape "new_project" {
  targets         = [{ __address__ = "172.18.0.1:3000" }]  // Any IP, will be auto-corrected
  metrics_path    = "/metrics"                              // Or /api/metrics
  forward_to      = [prometheus.remote_write.obs_plane.receiver]
  scrape_interval = "15s"
  job_name        = "new-project"
}
```

2. **Add a line** to `/opt/alloy/update-targets.sh`:
```bash
update_ip "COOLIFY_CONTAINER_PREFIX" "PORT"
```

3. **Find the prefix**: `docker ps --format "{{.Names}}" | grep -v alloy | grep -v coolify`

4. **Restart Alloy**: `cd /opt/alloy && HOSTNAME=$(hostname) docker compose restart alloy`

The cron job will keep the IP updated automatically from that point forward.

## Monitoring the Auto-Update

```bash
# See recent IP changes:
tail -20 /var/log/alloy-targets.log

# Verify all targets are UP in Prometheus:
curl -s 'http://10.0.1.50:9090/api/v1/query?query=up' | python3 -c '
import sys, json
for r in json.load(sys.stdin)["data"]["result"]:
    print(f"  {r[\"metric\"].get(\"job\",\"?\"):15s} {\"UP\" if r[\"value\"][1]==\"1\" else \"DOWN\"}")
'
```

## Resource Usage

| Component | RAM | CPU | Disk |
|-----------|-----|-----|------|
| Alloy agent | 128 MB limit | < 1% | ~50 MB (WAL) |
| Cron script | < 5 MB (runs 1 sec/min) | Negligible | Log file (~1 KB/day) |
