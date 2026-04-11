#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — Manual Deploy Script
# Usage: ./scripts/deploy.sh [service] [tag]
# Examples:
#   ./scripts/deploy.sh all              # Deploy all services (latest)
#   ./scripts/deploy.sh api abc1234      # Deploy API with specific tag
#   ./scripts/deploy.sh admin            # Deploy admin portal (latest)
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
  api)     deploy_service api ;;
  worker)  deploy_service worker ;;
  admin)   deploy_service admin ;;
  infra)
    echo "→ Pulling infrastructure services..."
    docker compose pull postgres redis rabbitmq traefik otel-collector pg-backup
    docker compose up -d postgres redis rabbitmq traefik otel-collector pg-backup
    ;;
  all)
    echo "→ Pulling all images..."
    docker compose pull
    echo "→ Restarting all services..."
    docker compose up -d
    ;;
  *)
    echo "Unknown service: $SERVICE"
    echo "Valid options: api, worker, admin, infra, all"
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
curl -sf https://api.aegisremit.ng/health 2>/dev/null && echo " ✓ API healthy" || echo " ✗ API unreachable"
curl -sf https://app.aegisremit.ng 2>/dev/null && echo " ✓ Admin healthy" || echo " ✗ Admin unreachable"
echo ""
echo "── Running containers ──"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
