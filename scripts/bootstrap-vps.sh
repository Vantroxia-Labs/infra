#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — VPS Bootstrap
# Target: Ubuntu 24.04 LTS on Contabo (or equivalent)
# Run once as root. Idempotent — safe to re-run.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Vantroxia-Labs/infra/main/scripts/bootstrap-vps.sh | sudo bash -s -- <SSH_PUB_KEY>
#   # or
#   sudo ./bootstrap-vps.sh "ssh-ed25519 AAAA... deploy@github-actions"
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

DEPLOY_USER="deploy"
DEPLOY_DIR="/opt/aegisremit"
SWAP_SIZE="2G"
DOCKER_WEB_NETWORK="aegisremit-web"
DOCKER_INTERNAL_NETWORK="aegisremit-internal"
SFTP_DATA_VOLUME="aegisremit-sftp-data"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Must run as root (use sudo)."

SSH_PUB_KEY="${1:-}"
[[ -n "$SSH_PUB_KEY" ]] || fail "Pass the CI public key as the first argument (ssh-ed25519 AAAA...)."

# ── 1. Base packages ──────────────────────────────────────────────────────
log "Updating apt and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg ufw fail2ban unattended-upgrades \
    apache2-utils jq htop

# ── 2. Docker (skip if already installed) ─────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log "Docker already installed: $(docker --version)"
fi

# ── 3. Deploy user ────────────────────────────────────────────────────────
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    log "Creating user '$DEPLOY_USER'..."
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="/home/$DEPLOY_USER/.ssh/authorized_keys"
touch "$AUTH_KEYS"
if ! grep -qxF "$SSH_PUB_KEY" "$AUTH_KEYS"; then
    echo "$SSH_PUB_KEY" >> "$AUTH_KEYS"
    log "Added CI public key to $AUTH_KEYS"
else
    log "CI public key already present in $AUTH_KEYS"
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# ── 4. Deploy directory ───────────────────────────────────────────────────
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_DIR"
log "Deploy directory: $DEPLOY_DIR (owned by $DEPLOY_USER)"

# ── 5. SSH hardening ──────────────────────────────────────────────────────
log "Hardening sshd..."
SSHD_CFG="/etc/ssh/sshd_config"
sed -i -E \
    -e 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
    -e 's/^#?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    "$SSHD_CFG"
systemctl reload ssh || systemctl reload sshd

# ── 6. Firewall ───────────────────────────────────────────────────────────
log "Configuring ufw..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ── 7. fail2ban + unattended-upgrades ─────────────────────────────────────
log "Enabling fail2ban and unattended-upgrades..."
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades

# ── 8. Swap file (insurance for memory spikes) ────────────────────────────
if ! swapon --show | grep -q '/swapfile'; then
    log "Creating ${SWAP_SIZE} swap file..."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    log "Swap already configured."
fi

# ── 9. Docker networks (shared across segregated compose stacks) ──────────
if ! docker network inspect "$DOCKER_WEB_NETWORK" >/dev/null 2>&1; then
    log "Creating docker network '$DOCKER_WEB_NETWORK'..."
    docker network create "$DOCKER_WEB_NETWORK"
else
    log "Docker network '$DOCKER_WEB_NETWORK' already exists."
fi

if ! docker network inspect "$DOCKER_INTERNAL_NETWORK" >/dev/null 2>&1; then
    log "Creating docker network '$DOCKER_INTERNAL_NETWORK' (internal)..."
    # --internal prevents direct outbound internet access from this network.
    # Services that need external connectivity (e.g. MinIO, RabbitMQ) are
    # also attached to the 'web' network, which allows outbound traffic.
    docker network create --internal "$DOCKER_INTERNAL_NETWORK"
else
    log "Docker network '$DOCKER_INTERNAL_NETWORK' already exists."
fi

# ── 10. Shared Docker volumes ─────────────────────────────────────────────
# sftp-data is shared between infra (sftpgo) and apps (sftp-api)
if ! docker volume inspect "$SFTP_DATA_VOLUME" >/dev/null 2>&1; then
    log "Creating shared volume '$SFTP_DATA_VOLUME'..."
    docker volume create "$SFTP_DATA_VOLUME"
else
    log "Docker volume '$SFTP_DATA_VOLUME' already exists."
fi

# ── 11. Summary ───────────────────────────────────────────────────────────
cat <<EOF

═══════════════════════════════════════════════════════════════════════════
  VPS bootstrap complete.

  Docker networks:  $DOCKER_WEB_NETWORK, $DOCKER_INTERNAL_NETWORK
  Shared volumes:   $SFTP_DATA_VOLUME
  Deploy directory: $DEPLOY_DIR

  Next steps (as the '$DEPLOY_USER' user):

  1. Copy infra files into $DEPLOY_DIR:
       scp -r Infra/traefik/ Infra/infra/ Infra/apps/ \\
         $DEPLOY_USER@<host>:$DEPLOY_DIR/
       scp Infra/.env.example Infra/otel-collector-config.yaml \\
         $DEPLOY_USER@<host>:$DEPLOY_DIR/

  2. Create $DEPLOY_DIR/.env from .env.example, then:
       chmod 600 $DEPLOY_DIR/.env

  3. Log in to GHCR so compose can pull private images:
       echo \$GHCR_PAT | docker login ghcr.io -u <github_user> --password-stdin

  4. Bootstrap each stack in order:
       cd $DEPLOY_DIR/traefik && docker compose --env-file ../.env up -d
       cd $DEPLOY_DIR/infra   && docker compose --env-file ../.env up -d
       cd $DEPLOY_DIR/apps    && docker compose --env-file ../.env up -d

═══════════════════════════════════════════════════════════════════════════
EOF
