#!/bin/sh
# ============================================================
# Provision a vhost + dedicated user for an application.
#   ./create-app-vhost.sh <app_name> <password>
# Example: ./create-app-vhost.sh gymmate 'S3cureP@ss'
# Creates: vhost "/gymmate", user "gymmate" scoped to it.
# Idempotent — safe to re-run.
# ============================================================
set -eu

APP="$1"
PASS="$2"
VHOST="/${APP}"

docker exec rabbitmq rabbitmqctl add_vhost "${VHOST}" 2>/dev/null || true
docker exec rabbitmq rabbitmqctl add_user "${APP}" "${PASS}" 2>/dev/null || \
  docker exec rabbitmq rabbitmqctl change_password "${APP}" "${PASS}"
docker exec rabbitmq rabbitmqctl set_permissions -p "${VHOST}" "${APP}" ".*" ".*" ".*"

echo "OK: vhost '${VHOST}' with user '${APP}'."
echo "    amqp://${APP}:***@rabbitmq:5672${VHOST}"
