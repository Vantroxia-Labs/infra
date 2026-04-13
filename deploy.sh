#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — Manual Deploy Script
# Usage: ./deploy.sh [service] [tag]
# Examples:
#   ./deploy.sh all                # Deploy all services (latest)
#   ./deploy.sh portal-api abc1234 # Deploy Portal API with specific tag
#   ./deploy.sh admin              # Deploy admin portal (latest)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SERVICE="${1:-all}"
TAG="${2:-latest}"
COMPOSE_DIR="/opt/aegisremit"

cd "$COMPOSE_DIR"

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
  echo ""
  echo "→ Pulling $svc..."
  docker compose pull "$svc"
  echo "→ Stopping $svc..."
  docker compose stop "$svc"
  echo "→ Starting $svc..."
  docker compose up -d --no-deps "$svc"
  echo "→ Waiting 5s for $svc..."
  sleep 5
  docker compose ps "$svc"
}

case "$SERVICE" in
  portal-api)  deploy_service portal-api ;;
  erp-api)     deploy_service erp-api ;;
  sftp-api)    deploy_service sftp-api ;;
  admin)       deploy_service admin ;;
  infra)
    echo "→ Pulling infrastructure services..."
    docker compose pull redis rabbitmq minio traefik otel-collector
    docker compose up -d redis rabbitmq minio traefik otel-collector
    ;;
  all)
    echo "→ Pulling all images..."
    docker compose pull
    echo "→ Restarting all services..."
    docker compose up -d
    ;;
  *)
    echo "Unknown service: $SERVICE"
    echo "Valid options: portal-api, erp-api, sftp-api, admin, infra, all"
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
curl -sf https://sftp-api.aegisremit.ng/health 2>/dev/null && echo " ✓ SFTP API healthy" || echo " ✗ SFTP API unreachable"
curl -sf https://app.aegisremit.ng 2>/dev/null && echo " ✓ Admin healthy" || echo " ✗ Admin unreachable"
echo ""
echo "── Running containers ──"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
