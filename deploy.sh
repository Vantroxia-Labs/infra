#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — Manual Deploy Script
# Usage: ./deploy.sh [service] [tag]
# Examples:
#   ./deploy.sh all                # Deploy all application services (latest)
#   ./deploy.sh infra              # Deploy infrastructure services
#   ./deploy.sh traefik            # Deploy Traefik reverse proxy
#   ./deploy.sh apps               # Deploy all application services
#   ./deploy.sh portal-api abc1234 # Deploy Portal API with specific tag
#   ./deploy.sh admin              # Deploy admin portal (latest)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SERVICE="${1:-all}"
TAG="${2:-latest}"
BASE_DIR="/opt/aegisremit"
ENV_FILE="--env-file ${BASE_DIR}/.env"

echo "═══════════════════════════════════════════"
echo "  AegisRemit — Manual Deploy"
echo "  Service: $SERVICE"
echo "  Tag:     $TAG"
echo "  Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════"

# Authenticate with GHCR
echo "$GHCR_TOKEN" | docker login ghcr.io -u vantroxia-labs --password-stdin

export IMAGE_TAG="$TAG"

deploy_service() {
  local svc=$1
  local dir=$2
  echo ""
  echo "→ Pulling $svc in $dir..."
  cd "$BASE_DIR/$dir"
  docker compose $ENV_FILE pull "$svc"
  echo "→ Stopping $svc..."
  docker compose $ENV_FILE stop "$svc"
  echo "→ Starting $svc..."
  docker compose $ENV_FILE up -d --no-deps "$svc"
  echo "→ Waiting 5s for $svc..."
  sleep 5
  docker compose $ENV_FILE ps "$svc"
}

# Apply EF Core migrations as a one-shot before rolling DB-backed apps.
# Production APIs do NOT auto-migrate. Connects to aegisremit-postgres over the
# internal network, so the infra stack (postgres) must already be running.
run_migrations() {
  echo ""
  echo "→ Applying database migrations (remit-migrator:$TAG)..."
  local db_conn
  db_conn=$(grep -E '^DB_CONNECTION_STRING=' "${BASE_DIR}/.env" | head -1 | cut -d= -f2-)
  if [ -z "$db_conn" ]; then
    echo "✗ DB_CONNECTION_STRING not found in ${BASE_DIR}/.env"
    exit 1
  fi
  docker pull "ghcr.io/vantroxia-labs/remit-migrator:$TAG"
  docker run --rm --network aegisremit-internal \
    -e "ConnectionStrings__DefaultConnection=$db_conn" \
    "ghcr.io/vantroxia-labs/remit-migrator:$TAG"
  echo "→ Migrations applied successfully."
}

case "$SERVICE" in
  portal-api)  run_migrations; deploy_service portal-api apps ;;
  erp-api)     run_migrations; deploy_service erp-api apps ;;
  admin)       deploy_service admin apps ;;
  all-apis)
    run_migrations
    cd "$BASE_DIR/apps"
    echo "→ Pulling all API images..."
    docker compose $ENV_FILE pull portal-api erp-api
    echo "→ Restarting all APIs..."
    docker compose $ENV_FILE up -d --no-deps portal-api erp-api
    sleep 5
    docker compose $ENV_FILE ps
    ;;
  apps)
    run_migrations
    cd "$BASE_DIR/apps"
    echo "→ Pulling all application images..."
    docker compose $ENV_FILE pull portal-api erp-api admin
    echo "→ Restarting all application services..."
    docker compose $ENV_FILE up -d --no-deps portal-api erp-api admin
    sleep 5
    docker compose $ENV_FILE ps
    ;;
  infra)
    cd "$BASE_DIR/infra"
    echo "→ Pulling infrastructure services..."
    docker compose $ENV_FILE pull
    docker compose $ENV_FILE up -d
    ;;
  traefik)
    cd "$BASE_DIR/traefik"
    echo "→ Pulling Traefik..."
    docker compose $ENV_FILE pull
    docker compose $ENV_FILE up -d
    ;;
  all)
    cd "$BASE_DIR/traefik"
    echo "→ Updating Traefik..."
    docker compose $ENV_FILE pull
    docker compose $ENV_FILE up -d

    cd "$BASE_DIR/infra"
    echo "→ Updating infrastructure..."
    docker compose $ENV_FILE pull
    docker compose $ENV_FILE up -d
    echo "→ Waiting for postgres to be ready..."
    sleep 10

    run_migrations

    cd "$BASE_DIR/apps"
    echo "→ Updating applications..."
    docker compose $ENV_FILE pull
    docker compose $ENV_FILE up -d
    ;;
  *)
    echo "Unknown service: $SERVICE"
    echo "Valid options: portal-api, erp-api, admin, all-apis, apps, infra, traefik, all"
    exit 1
    ;;
esac

# Cleanup
docker image prune -f

echo ""
echo "═══════════════════════════════════════════"
echo "  Deploy complete!"
echo "═══════════════════════════════════════════"
echo ""

# Health checks
echo "── Health checks ──"
curl -sf https://api.aegisremit.ng/health 2>/dev/null && echo " ✓ Portal API healthy" || echo " ✗ Portal API unreachable"
curl -sf https://erp.aegisremit.ng/health 2>/dev/null && echo " ✓ ERP API healthy" || echo " ✗ ERP API unreachable"
curl -sf https://app.aegisremit.ng 2>/dev/null && echo " ✓ Admin healthy" || echo " ✗ Admin unreachable"
echo ""
echo "── Running containers ──"
echo "--- Traefik ---"
cd "$BASE_DIR/traefik" && docker compose $ENV_FILE ps --format "table {{.Name}}\t{{.Status}}"
echo "--- Infrastructure ---"
cd "$BASE_DIR/infra" && docker compose $ENV_FILE ps --format "table {{.Name}}\t{{.Status}}"
echo "--- Applications ---"
cd "$BASE_DIR/apps" && docker compose $ENV_FILE ps --format "table {{.Name}}\t{{.Status}}"
