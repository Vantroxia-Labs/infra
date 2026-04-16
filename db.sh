#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — Database Backup & Restore
# Usage:
#   ./scripts/db.sh backup              # Create a backup
#   ./scripts/db.sh restore <file>      # Restore from backup
#   ./scripts/db.sh list                # List available backups
#   ./scripts/db.sh download            # Download latest backup to local
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

COMPOSE_DIR="/opt/aegisremit"
BACKUP_DIR="/opt/aegisremit/backups"
CONTAINER="aegisremit-postgres"

cd "$COMPOSE_DIR"

# Load env vars
source .env

case "${1:-help}" in
  backup)
    FILENAME="aegisremit_$(date +%Y%m%d_%H%M%S).sql.gz"
    echo "→ Creating backup: $FILENAME"
    mkdir -p "$BACKUP_DIR"
    docker exec "$CONTAINER" pg_dump -U "$PG_USER" -d aegisremit | gzip > "$BACKUP_DIR/$FILENAME"
    echo "✓ Backup saved: $BACKUP_DIR/$FILENAME ($(du -h "$BACKUP_DIR/$FILENAME" | cut -f1))"

    # Keep only last 14 backups
    ls -1t "$BACKUP_DIR"/aegisremit_*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm
    echo "✓ Old backups cleaned (keeping last 14)"
    ;;

  restore)
    FILE="${2:-}"
    if [ -z "$FILE" ]; then
      echo "Usage: $0 restore <backup_file>"
      echo "Available backups:"
      ls -1t "$BACKUP_DIR"/aegisremit_*.sql.gz 2>/dev/null || echo "  (none)"
      exit 1
    fi

    echo "⚠ WARNING: This will REPLACE the current database!"
    echo "  File: $FILE"
    read -p "  Continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "Aborted."
      exit 0
    fi

    echo "→ Stopping application services..."
    docker compose --env-file ../.env -f /opt/aegisremit/apps/docker-compose.yml stop portal-api erp-api sftp-api

    echo "→ Restoring from $FILE..."
    gunzip -c "$FILE" | docker exec -i "$CONTAINER" psql -U "$PG_USER" -d aegisremit

    echo "→ Restarting application services..."
    docker compose --env-file ../.env -f /opt/aegisremit/apps/docker-compose.yml start portal-api erp-api sftp-api

    echo "✓ Restore complete"
    ;;

  list)
    echo "Available backups:"
    ls -lhtr "$BACKUP_DIR"/aegisremit_*.sql.gz 2>/dev/null || echo "  (none)"
    ;;

  download)
    LATEST=$(ls -1t "$BACKUP_DIR"/aegisremit_*.sql.gz 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then
      echo "No backups found. Run: $0 backup"
      exit 1
    fi
    echo "Latest backup: $LATEST"
    echo "Download with: scp deploy@YOUR_VPS_IP:$LATEST ."
    ;;

  *)
    echo "Usage: $0 {backup|restore|list|download}"
    exit 1
    ;;
esac
