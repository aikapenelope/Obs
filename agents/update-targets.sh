#!/bin/bash
# =============================================================================
# Auto-Update Alloy Scrape Targets
#
# Solves the problem of Docker container IPs changing on every redeploy.
# Runs every minute via cron. Only restarts Alloy if IPs actually changed.
#
# How it works:
#   1. Finds containers by their stable name prefix (Coolify prefixes never change)
#   2. Gets the current IP of each container from Docker inspect
#   3. Compares with the IP currently in Alloy's config
#   4. If any IP changed: updates config + restarts Alloy
#   5. If nothing changed: does nothing (no unnecessary restarts)
#
# Why this approach:
#   - Port Mappings in Coolify break Rolling Updates (documented limitation)
#   - Custom Container Names break Rolling Updates (tested, confirmed)
#   - network_mode:host prevents joining the coolify Docker network
#   - This script is non-invasive: only reads Docker state, never modifies containers
#
# Install:
#   cp update-targets.sh /opt/alloy/
#   chmod +x /opt/alloy/update-targets.sh
#   echo "* * * * * root /opt/alloy/update-targets.sh >> /var/log/alloy-targets.log 2>&1" > /etc/cron.d/alloy-targets
#
# To add a new project:
#   1. Add a prometheus.scrape block to /opt/alloy/config.alloy with any IP
#   2. Add an update_ip line below with the container prefix and port
#   3. The script will auto-correct the IP on next run
# =============================================================================

set -euo pipefail

CONFIG="/opt/alloy/config.alloy"
CHANGED=false

update_ip() {
  local PREFIX="$1" PORT="$2"
  local CONTAINER=$(docker ps --format "{{.Names}}" | grep "^${PREFIX}" | head -1)
  if [ -z "$CONTAINER" ]; then return; fi
  local NEW_IP=$(docker inspect "$CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' 2>/dev/null | head -1)
  if [ -z "$NEW_IP" ]; then return; fi
  
  local CURRENT=$(grep -oP "(?<=__address__ = \")[0-9.]+(?=:${PORT}\")" "$CONFIG" | head -1)
  if [ "$CURRENT" != "$NEW_IP" ] && [ -n "$NEW_IP" ]; then
    sed -i "s|\"${CURRENT}:${PORT}\"|\"${NEW_IP}:${PORT}\"|" "$CONFIG"
    CHANGED=true
    echo "$(date): ${PREFIX} IP changed: ${CURRENT} -> ${NEW_IP}"
  fi
}

# === PROJECT TARGETS ===
# Format: update_ip "container_name_prefix" "metrics_port"
# The prefix is the stable part of the Coolify container name (before the numeric suffix)

update_ip "w0o0k4owsw8s0csscocwwk0s" "3001"   # Nova API (Hono, /metrics)
update_ip "wo8w0okogc4ko80owsos44sk" "3000"    # Propi (Next.js, /api/metrics)
update_ip "tock4scgsws88k4okk4wo0so" "3000"    # Aurora (Nuxt, /api/metrics)
update_ip "c4g8gckwwkggwgkogcsswsgg" "4000"    # DocFlow API (NestJS, /api/metrics/metrics)

# === RESTART IF CHANGED ===
if [ "$CHANGED" = true ]; then
  cd /opt/alloy && HOSTNAME=$(hostname) docker compose restart alloy > /dev/null 2>&1
  echo "$(date): Alloy restarted with new IPs"
fi
