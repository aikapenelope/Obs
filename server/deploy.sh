#!/bin/bash
# =============================================================================
# Observability Plane — Deploy Script
#
# Deploys the complete observability stack on a fresh Ubuntu VPS.
# Requirements: Ubuntu 22.04+ with Docker and Docker Compose v2 installed.
#
# Usage:
#   ./deploy.sh
#
# What it does:
#   1. Generates secrets (Grafana password, Bugsink key) if not already set
#   2. Starts all services (Loki, Prometheus, Grafana, Alloy, Bugsink)
#   3. Waits for health checks
#   4. Creates Bugsink projects
#   5. Prints access URLs and credentials
#
# After running this script:
#   - Configure Prometheus targets in prometheus.yml
#   - Install agents on other servers (see agents/install.sh)
#   - Configure Telegram alerts in Grafana
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"

echo "=== Observability Plane Deploy ==="
echo ""

# --- Generate .env if not exists ---
if [ ! -f .env ]; then
  echo "Generating secrets..."
  GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
  BUGSINK_KEY=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
  BUGSINK_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)

  cat > .env << EOF
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASS}
GRAFANA_ROOT_URL=http://$(hostname):3000
BUGSINK_SECRET_KEY=${BUGSINK_KEY}
BUGSINK_ADMIN_PASSWORD=${BUGSINK_PASS}
EOF
  chmod 600 .env
  echo "  .env created with generated secrets"
else
  echo "  .env already exists, using existing secrets"
fi

source .env

# --- Pull and start services ---
echo ""
echo "Pulling images..."
docker compose pull -q

echo "Starting services..."
docker compose up -d

# --- Wait for health ---
echo ""
echo "Waiting for services to be healthy..."
for i in $(seq 1 30); do
  HEALTHY=$(docker ps --filter "health=healthy" --format "{{.Names}}" | wc -l)
  if [ "$HEALTHY" -ge 3 ]; then
    echo "  $HEALTHY/5 services healthy"
    break
  fi
  sleep 2
done

# --- Create Bugsink projects ---
echo ""
echo "Creating Bugsink projects..."
MANAGE="/usr/local/lib/python3.12/site-packages/bugsink/scripts/manage.py"
docker exec obs-bugsink python $MANAGE shell -c "
from projects.models import Project
for name in ['nova', 'whabi', 'docflow', 'aurora', 'propi']:
    p, created = Project.objects.get_or_create(name=name)
    status = 'created' if created else 'exists'
    print(f'  {name}: id={p.id} ({status}) DSN=http://{p.sentry_key}@<OBS_PLANE_IP>:8000/{p.id}')
" 2>/dev/null || echo "  (Bugsink not ready yet, create projects manually later)"

# --- Print summary ---
echo ""
echo "=== Deploy Complete ==="
echo ""
echo "Access URLs:"
echo "  Grafana:    http://$(hostname):3000"
echo "  Bugsink:    http://$(hostname):8000"
echo "  Prometheus: http://$(hostname):9090"
echo "  Loki:       http://$(hostname):3100"
echo ""
echo "Credentials:"
echo "  Grafana:  admin / $GRAFANA_ADMIN_PASSWORD"
echo "  Bugsink:  admin / $BUGSINK_ADMIN_PASSWORD"
echo ""
echo "Next steps:"
echo "  1. Edit prometheus.yml to add your scrape targets"
echo "  2. Run: docker compose restart prometheus"
echo "  3. Install agents on other servers: ../agents/install.sh <OBS_PLANE_IP>"
echo "  4. Configure Telegram alerts in Grafana UI"
echo ""
