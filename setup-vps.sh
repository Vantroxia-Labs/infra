#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# AegisRemit — Contabo VPS Initial Setup
# Run as root on a fresh Ubuntu 24.04 LTS instance
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

echo "══════════════════════════════════════════"
echo "  AegisRemit VPS Setup — Contabo SG"
echo "══════════════════════════════════════════"

# ── 1. System updates ─────────────────────────────────────────────────────
apt update && apt upgrade -y
apt install -y curl git ufw fail2ban htop ncdu

# ── 2. Create deploy user ─────────────────────────────────────────────────
useradd -m -s /bin/bash deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# ── 3. Firewall ───────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (Traefik)
ufw allow 443/tcp   # HTTPS (Traefik)
ufw --force enable

# ── 4. SSH hardening ──────────────────────────────────────────────────────
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

# ── 5. Install Docker ─────────────────────────────────────────────────────
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy

# ── 6. Install Docker Compose plugin ──────────────────────────────────────
apt install -y docker-compose-plugin

# ── 7. Create project directory ───────────────────────────────────────────
mkdir -p /opt/aegisremit/config
chown -R deploy:deploy /opt/aegisremit

# ── 8. Swap (safety net on 8GB box) ──────────────────────────────────────
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "vm.swappiness=10" >> /etc/sysctl.conf
  sysctl -p
fi

# ── 9. Fail2ban config ───────────────────────────────────────────────────
systemctl enable fail2ban
systemctl start fail2ban

echo ""
echo "══════════════════════════════════════════"
echo "  Setup complete!"
echo "  Next steps:"
echo "  1. Log in as: ssh deploy@YOUR_VPS_IP"
echo "  2. Copy files to /opt/aegisremit/"
echo "  3. Create .env from .env.example"
echo "  4. Run: docker compose up -d"
echo "══════════════════════════════════════════"
