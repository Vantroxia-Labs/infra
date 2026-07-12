#!/bin/sh
# ============================================================
# Vantroxia Labs — FRESH INSTALL (destructive!)
# Tears down the old aegisremit-branded setup, wipes volumes,
# and brings up the new three-stack layout.
#
# Run from /opt/vantroxia:  ./scripts/fresh-install.sh
# Prereqs: infra/.env and apps/aegisremit/.env filled in,
#          traefik/.env has TRAEFIK_DASHBOARD_AUTH + BASE_DOMAIN,
#          your IP set in traefik/dynamic/middlewares.yml
# ============================================================
set -eu

echo "=== 1/6 Stopping old stacks in /opt/aegisremit (if present) ==="
if [ -d /opt/aegisremit ]; then
  for d in /opt/aegisremit /opt/aegisremit/infra /opt/aegisremit/traefik /opt/aegisremit/apps; do
    [ -f "$d/docker-compose.yml" ] && (cd "$d" && docker compose down --remove-orphans) || true
  done
fi
# Catch anything left over
docker ps -aq --filter "name=aegisremit-" | xargs -r docker rm -f
docker ps -aq --filter "name=traefik" | xargs -r docker rm -f

echo "=== 2/6 Removing old volumes (FRESH START — data is destroyed) ==="
docker volume rm -f \
  aegisremit-postgres-data aegisremit-sftp-data \
  infra_minio-data infra_rabbitmq-data infra_redis-data \
  infra_sftpgo-data infra_sftpgo-home infra_sftpgo-backups \
  traefik_traefik-certs traefik_traefik-logs 2>/dev/null || true

echo "=== 3/6 Removing old networks, creating shared ones ==="
docker network rm aegisremit-internal aegisremit-web 2>/dev/null || true
docker network inspect proxy   >/dev/null 2>&1 || docker network create proxy
docker network inspect backend >/dev/null 2>&1 || docker network create backend

echo "=== 4/6 Starting Traefik ==="
cd "$(dirname "$0")/.."
(cd traefik && docker compose up -d)

echo "=== 5/6 Starting shared infrastructure ==="
(cd infra && docker compose up -d)
echo "Waiting for PostgreSQL to be healthy..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' postgres)" = "healthy" ]; do sleep 2; done
echo "Waiting for RabbitMQ to be healthy..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' rabbitmq)" = "healthy" ]; do sleep 3; done

echo "=== 6/6 Provisioning AegisRemit resources ==="
# Read passwords from the app .env so they stay in one place
AEGISREMIT_DB_PASSWORD=$(grep '^AEGISREMIT_DB_PASSWORD=' apps/aegisremit/.env | cut -d= -f2-)
AEGISREMIT_MQ_PASSWORD=$(grep '^AEGISREMIT_MQ_PASSWORD=' apps/aegisremit/.env | cut -d= -f2-)

./infra/postgres/create-app-db.sh aegisremit "$AEGISREMIT_DB_PASSWORD"
./infra/rabbitmq/create-app-vhost.sh aegisremit "$AEGISREMIT_MQ_PASSWORD"

echo "=== Starting AegisRemit ==="
(cd apps/aegisremit && docker compose up -d)

echo ""
echo "All done. Verify with:"
echo "  docker ps"
echo "  docker stats --no-stream"
echo "  curl -I https://api.aegisremit.ng"
