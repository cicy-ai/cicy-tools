#!/usr/bin/env bash
# cicy-cloudshell-ssh.sh — minimal SSH daemon on Cloud Shell, served over the
# existing cloudflared Named Tunnel so NO frp / public-ip is needed.
#
# The tunnel hostname (cloudshell.cicy-ai.com) already routes HTTP to :8008; this
# script adds an sshd on :2022 and the tunnel ingress `ssh://localhost:2022` must
# be configured on the Cloudflare side (do it once in the dashboard or via API).
#
# Usage (on every Cloud Shell restart):
#   curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell-ssh.sh | bash
#
# Then connect from your client:
#   cloudflared access ssh --hostname cloudshell.cicy-ai.com
set -euo pipefail

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }

PORT="${SSHD_PORT:-2022}"

# ── authorized keys ──────────────────────────────────────────────────────
# Override in ~/config.ini (bash-sourced array SSH_PUBKEYS). The built-in
# fallback is the cicy team default keypair.
CONFIG="${CICY_CONFIG:-$HOME/config.ini}"
if [ -f "$CONFIG" ]; then
  set -a; . "$CONFIG"; set +a
  ok "loaded $CONFIG"
fi
if [ -z "${SSH_PUBKEYS+x}" ]; then
  SSH_PUBKEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKWMycBp5+3owB6EFEl8vKGDe8CkRvGeBaHCldVWZSb5 linux-w10125"
  )
fi

# ── cicy user ────────────────────────────────────────────────────────────
log "cicy user + SSH keys"
CICY_UID=1001; CICY_GID=1001
if ! id -u cicy >/dev/null 2>&1; then
  sudo groupadd -g "$CICY_GID" cicy 2>/dev/null || true
  sudo useradd -u "$CICY_UID" -g "$CICY_GID" -m -d /home/cicy -s /bin/bash cicy 2>/dev/null || true
  ok "created cicy (uid $CICY_UID)"
else
  ok "cicy already exists"
fi
sudo usermod -s /bin/bash -d /home/cicy cicy 2>/dev/null || true
sudo mkdir -p /home/cicy && sudo chown cicy:cicy /home/cicy
sudo passwd -u cicy >/dev/null 2>&1 || true
echo "cicy:$(openssl rand -base64 18 2>/dev/null || echo "cicy${RANDOM}${RANDOM}")" | sudo chpasswd 2>/dev/null || true
echo "cicy ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-cicy >/dev/null && sudo chmod 440 /etc/sudoers.d/90-cicy
sudo install -d -m700 -o cicy -g cicy /home/cicy/.ssh
for K in "${SSH_PUBKEYS[@]}"; do
  sudo grep -qF "$K" /home/cicy/.ssh/authorized_keys 2>/dev/null || echo "$K" | sudo tee -a /home/cicy/.ssh/authorized_keys >/dev/null
done
sudo chmod 600 /home/cicy/.ssh/authorized_keys && sudo chown -R cicy:cicy /home/cicy/.ssh
ok "authorized_keys: $(sudo grep -c . /home/cicy/.ssh/authorized_keys 2>/dev/null || echo 0) key(s)"

# ── sshd on $PORT ───────────────────────────────────────────────────────
log "sshd on :$PORT"
sudo mkdir -p /run/sshd-cicy
sudo tee /etc/ssh/sshd_config.cicy >/dev/null <<EOF
Port $PORT
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile /home/cicy/.ssh/authorized_keys
StrictModes no
UsePAM no
PidFile /run/sshd-cicy/pid
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Kill any prior instance first
sudo pkill -F /run/sshd-cicy/pid 2>/dev/null || true
sleep 1

if sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.cicy 2>/dev/null && \
   { sleep 1; pgrep -f 'sshd_config.cicy' >/dev/null 2>&1; }; then
  ok "sshd running on :$PORT (pubkey only, user cicy)"
else
  warn "sshd failed — debug: sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.cicy -d"
  exit 1
fi

echo
echo "============================================================"
echo "  SSH via cloudflared tunnel (no frp / no public IP needed):"
echo "    cloudflared access ssh --hostname cloudshell.cicy-ai.com"
echo ""
echo "  Or add to ~/.ssh/config on your client:"
echo "    Host cloudshell"
echo "        HostName cloudshell.cicy-ai.com"
echo "        User cicy"
echo "        ProxyCommand cloudflared access ssh --hostname cloudshell.cicy-ai.com"
echo ""
echo "  Then just:  ssh cloudshell"
echo "============================================================"
