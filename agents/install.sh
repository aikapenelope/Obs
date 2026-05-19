#!/bin/bash
# =============================================================================
# Grafana Alloy Agent — Install Script
#
# Installs the Alloy telemetry agent on any server to send logs and metrics
# to the Observability Plane.
#
# Usage:
#   ./install.sh <OBS_PLANE_IP>
#
# Example:
#   ./install.sh 10.0.1.50
#   ./install.sh 100.112.10.21
#
# What it does:
#   1. Creates /opt/alloy/ with config and docker-compose
#   2. Starts the Alloy agent container
#   3. Agent auto-discovers ALL Docker containers on this server
#   4. Sends logs to Loki and metrics to Prometheus on the Obs Plane
#
# Auto-discovery:
#   When Coolify (or anything) deploys a new container, Alloy detects it
#   automatically within 5 seconds. No configuration needed per container.
# =============================================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <OBS_PLANE_IP>"
  echo "Example: $0 10.0.1.50"
  exit 1
fi

OBS_IP="$1"
HOSTNAME=$(hostname)

echo "=== Installing Alloy Agent ==="
echo "  Hostname: $HOSTNAME"
echo "  Obs Plane: $OBS_IP"
echo ""

mkdir -p /opt/alloy

cat > /opt/alloy/config.alloy << EOF
// Grafana Alloy Agent — auto-discovers all Docker containers
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers" {
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
  targets    = discovery.relabel.containers.output
  forward_to = [loki.process.pipeline.receiver]
}

loki.process "pipeline" {
  stage.static_labels {
    values = { hostname = "$HOSTNAME" }
  }
  forward_to = [loki.write.obs_plane.receiver]
}

loki.write "obs_plane" {
  endpoint {
    url = "http://$OBS_IP:3100/loki/api/v1/push"
  }
}

prometheus.exporter.unix "node" {
  set_collectors = ["cpu", "meminfo", "diskstats", "filesystem", "loadavg", "netdev"]
}

prometheus.scrape "node_metrics" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.obs_plane.receiver]
  scrape_interval = "15s"
}

prometheus.remote_write "obs_plane" {
  endpoint {
    url = "http://$OBS_IP:9090/api/v1/write"
  }
}
EOF

cat > /opt/alloy/docker-compose.yml << 'COMPOSE'
services:
  alloy:
    image: grafana/alloy:v1.16.1
    container_name: alloy-agent
    restart: unless-stopped
    environment:
      - HOSTNAME
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/log:/var/log:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - alloy_positions:/var/lib/alloy
    network_mode: host
    pid: host
    command: run /etc/alloy/config.alloy
    deploy:
      resources:
        limits:
          memory: 128M

volumes:
  alloy_positions:
COMPOSE

cd /opt/alloy
HOSTNAME=$HOSTNAME docker compose pull -q
HOSTNAME=$HOSTNAME docker compose up -d

echo ""
echo "=== Agent Installed ==="
echo "  Container: alloy-agent (running)"
echo "  Logs → $OBS_IP:3100 (Loki)"
echo "  Metrics → $OBS_IP:9090 (Prometheus)"
echo "  Auto-discovers all Docker containers on this server"
echo ""
