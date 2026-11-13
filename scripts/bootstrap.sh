#!/usr/bin/env bash
#
# bootstrap.sh - harden a freshly reinstalled Ubuntu 24.04 VPS and install Dokploy.
#
# Run as root on a CLEAN server (nothing listening on 80, 443 or 3000):
#
#   scp scripts/bootstrap.sh root@207.180.197.64:/root/
#   ssh root@207.180.197.64
#   ADMIN_USER=godswill bash /root/bootstrap.sh
#
# Variables:
#   ADMIN_USER   sudo user to create (required)
#   SSH_PUBKEY   public key for ADMIN_USER (default: the key(s) in root's authorized_keys,
#                which Contabo fills in when you paste a key during Reinstall)
#   SWAP_SIZE    swap file size (default 4G; 0 to skip)
#   TIMEZONE     server timezone (default UTC)
#
# What it does:
#   1. Updates the OS and turns on automatic security updates
#   2. Creates a sudo user with your SSH key; turns off root login and password login
#   3. Enables UFW (22, 80, 443, plus 3000 for first-time setup) and fail2ban
#   4. Adds swap and Docker log rotation
#   5. Installs Dokploy (Docker, Swarm, Traefik, Dokploy's own Postgres and Redis)
#
# Keep this SSH session open until you've logged in as ADMIN_USER from a second
# terminal. If you ever lock yourself out, use the VNC console in the Contabo panel.
#
# Note: ports published by Docker/Swarm skip UFW. UFW protects SSH and host services;
# the Contabo firewall (Firewall tab in the panel) is what guards container ports.

set -euo pipefail

ADMIN_USER="${ADMIN_USER:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
TIMEZONE="${TIMEZONE:-UTC}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- preflight
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -n "$ADMIN_USER" ]] || die "Set ADMIN_USER, e.g.: ADMIN_USER=godswill bash bootstrap.sh"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ADMIN_USER must be a lowercase Linux username."

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  warn "Written for Ubuntu 24.04; this is ${PRETTY_NAME:-unknown}. Continuing in 10s (Ctrl-C to stop)."
  sleep 10
fi

for port in 80 443 3000; do
  if ss -ltnH "sport = :$port" | grep -q .; then
    die "Port $port is in use. Dokploy needs 80, 443 and 3000 free; start from a clean OS install."
  fi
done

if [[ -z "$SSH_PUBKEY" && -s /root/.ssh/authorized_keys ]]; then
  SSH_PUBKEY="$(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)"
fi
[[ -n "$SSH_PUBKEY" ]] || die "No SSH key found. Pass SSH_PUBKEY=\"ssh-ed25519 AAAA... you@laptop\" (password login is about to be turned off)."

# --------------------------------------------------------------------------- 1. OS updates
log "Updating the system"
apt-get update -y
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
apt-get install -y ufw fail2ban python3-systemd unattended-upgrades curl ca-certificates jq htop

timedatectl set-timezone "$TIMEZONE"

log "Turning on automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# --------------------------------------------------------------------------- 2. admin user + SSH
log "Creating sudo user '$ADMIN_USER'"
id "$ADMIN_USER" &>/dev/null || useradd -m -s /bin/bash "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
printf '%s\n' "$SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

if [[ -t 0 ]]; then
  echo "Set a password for '$ADMIN_USER'. It's only for sudo; SSH stays key-only."
  until passwd "$ADMIN_USER"; do echo "Try again."; done
else
  warn "No terminal attached, so '$ADMIN_USER' gets passwordless sudo."
  warn "Later: run 'sudo passwd $ADMIN_USER' and delete /etc/sudoers.d/90-$ADMIN_USER."
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
  chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
  visudo -cf "/etc/sudoers.d/90-$ADMIN_USER" >/dev/null
fi

log "Hardening SSH (keys only, no root login)"
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
cat > "$SSHD_DROPIN" <<EOF
# Written by bootstrap.sh. sshd uses the first value it reads, so this file
# overrides later ones such as 50-cloud-init.conf.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowUsers $ADMIN_USER
EOF
mkdir -p /run/sshd
if ! sshd -t; then
  rm -f "$SSHD_DROPIN"
  die "sshd config test failed; removed $SSHD_DROPIN and left SSH unchanged."
fi
systemctl reload ssh || systemctl restart ssh

# --------------------------------------------------------------------------- 3. firewall + fail2ban
log "Configuring UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000/tcp comment 'Dokploy first-time setup; close once the panel domain is live'
ufw --force enable

log "Configuring fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true

[sshd]
enabled = true
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# --------------------------------------------------------------------------- 4. swap, sysctl, Docker logs
if [[ "$SWAP_SIZE" != "0" ]] && ! swapon --show --noheadings | grep -q .; then
  log "Adding $SWAP_SIZE swap"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat > /etc/sysctl.d/99-vantroxia.conf <<'EOF'
vm.swappiness = 10
fs.inotify.max_user_watches = 524288
EOF
sysctl --system >/dev/null

log "Setting Docker log rotation (before Docker is installed)"
install -d /etc/docker
if [[ ! -s /etc/docker/daemon.json ]]; then
  # No "live-restore" here: it doesn't work with Swarm, which Dokploy uses.
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
fi

# --------------------------------------------------------------------------- 5. Dokploy
log "Installing Dokploy"
curl -fsSL https://dokploy.com/install.sh -o /tmp/dokploy-install.sh
sh /tmp/dokploy-install.sh

IP="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<EOF

$(printf '\033[1;32m')Done.$(printf '\033[0m') Next steps:

  1. From a NEW terminal:  ssh $ADMIN_USER@$IP   then run: sudo -v
     Close this root session only after that works.

  2. Open http://$IP:3000 right away and create the Dokploy admin account.
     Until an admin exists, whoever reaches that page first can claim it.

  3. Reboot when convenient so the updated kernel loads:  sudo reboot
     Dokploy and everything it runs come back up on their own.

EOF

