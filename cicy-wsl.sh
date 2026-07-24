#!/usr/bin/env bash
# cicy-wsl.sh — expose THIS Windows WSL distro's SSH through the cicy frp gateway.
# All connection params come IN via env (the caller / skill passes them) — no
# gateway domain or port is hardcoded here.
#
# Run INSIDE WSL (Ubuntu/Debian distro):
#   FRP_TOKEN=… FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… \
#     bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-wsl.sh)
#
# Then from anywhere:  ssh -p <FRP_REMOTE_PORT> root@<gateway>
#
# WSL notes:
#   • WSL2 is NAT'd behind Windows, but frpc dials OUT to the gateway, so the
#     reverse tunnel works without any Windows port-forward.
#   • WSL has its own network namespace — sshd on :22 here never collides with
#     Windows' own OpenSSH.
#   • Persistence: if the distro has systemd (`[boot] systemd=true` in
#     /etc/wsl.conf, Win11 / recent WSL) we install systemd units so sshd+frpc
#     survive `wsl --shutdown`. Otherwise we nohup them and print the Windows
#     Task-Scheduler one-liner to auto-start on logon.
set -uo pipefail

# required — passed IN via env (no domain/port here) —
: "${FRP_SERVER:?FRP_SERVER 未设置(由 skill/caller 传入)}"
: "${FRP_PORT:?FRP_PORT 未设置}"
: "${FRP_REMOTE_PORT:?FRP_REMOTE_PORT 未设置}"
: "${FRP_TOKEN:?FRP_TOKEN 未设置}"
FRP_NAME="${FRP_NAME:-wsl-ssh}"                 # frp proxy name (unique per box)
FRP_VER="${FRP_VER:-0.68.1}"
# team public keys (authorized on root; add more lines)
SSH_PUBKEYS=(
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCPgC8sASyJ2dMtDvKeC5j6L5UnOB1qnWxpQrWQ6j4pElI90yM0pJ0ZdQEfQlzciQ9o5BQeYInUap1UeOU909vWirAaYSZ2jhGZrjloC1ozpxHLcNTIHkEyxboNutFPdHm8fwVOy8GFDtpLarD+ZzV3atcOLvnnbPtohKFgnaqaP1fEvXlJg4Vsu64YfUrfyEnP+8htpam44tZUHn24VaZW/Vu+B29ESa4SM2CMbQdlzPs2m/wtL7vwFGeTmzhj8vLjCXv+dBz/l0DOb2n6N6wAaeowKS0cZtMu3OyuMbdHBWrQt4dfvvCZq6IKllr13v/CuzJ68CMh6g0hFccKf+6qvbcxOGyXuzxUxWpznLd+0EWlX+mWus43Y7I093qLKKEurk5N+r5p5WoKCAnk+wFZHvW50lPqPHySG741XaMeSMti3jY0CxJxJMHqZv1TWkpUAWkyPD6V3Srdu+LKR/W1c6Mj2xSwzVUwHzJKrBzOSRJlJw/0XYRI+a8/eHII3a2xbG/ShUXOJF8xuGsBhANw7FYzmDGK6AEnLs/QMn9PSxQTWRTwwmkKISP/SOSBFW/p/rlP6RPp1tgagTWDl9HLTOe5we/4b4JzbhEmgVedUA8QYXAxeljoQCaNgg4oPH/BxWv423Cp+PvF7xnqbb5seWwjqgzBcPXerf94tUQfTw== cicy@0cadebc15708"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKWMycBp5+3owB6EFEl8vKGDe8CkRvGeBaHCldVWZSb5 linux-w10125"
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDyMqv3jOo/FBGsvvCAli5yM15qNUMEcLkB+GripAUh4ng16WxE0SLXBl6EKE9YuVDjk1HSBvm41CV4nHpXukJQQmv1NJbwTr/ZgI2swG/SRQ+jDceiQcfGTRzW0fIvHzdYXiBKSHrH0ChC7u/aRwmubtxKv9XZ1AZn7PtphKn4r3oqlv8xNDwIlVqRR8ycza3x4ZYfpSe9JNrLCxY9rnk2V1z5C4SPgo70QXPnWNvPIMKLnlcoDXGy1049rZGsye3oi3WSwAVHoBhQbNxBt7iu1AZtB8nMd66SAfjeWURSzCZIAmJqX6XKsbGC11GOl+RRz2ZBvG1b3qiV1wDQ1x6p ton@jacks-MacBook-Pro.local"
)

log(){  printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$*"; }
info(){ printf '    \033[2m%s\033[0m\n' "$*"; }
SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) FARCH=amd64;; aarch64|arm64) FARCH=arm64;; *) FARCH=amd64;; esac
HAS_SYSTEMD=0; [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=1

printf '\033[1;35m══════════ CiCy WSL SSH tunnel setup ══════════\033[0m\n'
grep -qi microsoft /proc/version 2>/dev/null || warn "not detected as WSL (/proc/version has no 'microsoft') — continuing anyway"
info "distro:  $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")   ($ARCH → frp $FARCH)"
info "systemd: $([ "$HAS_SYSTEMD" = 1 ] && echo yes || echo 'no — will nohup + Task-Scheduler hint')"
info "gateway: $FRP_SERVER:$FRP_PORT   proxy: $FRP_NAME   public-port: $FRP_REMOTE_PORT"

log "1/3  sshd — install + authorize keys + start"
$SUDO apt-get -qq update >/dev/null 2>&1 || true
if $SUDO apt-get -qq install -y openssh-server >/dev/null 2>&1; then ok "openssh-server ready ($(dpkg -l openssh-server 2>/dev/null | awk '/^ii/{print $3; exit}'))"; else warn "apt install failed (maybe already present)"; fi
$SUDO mkdir -p /run/sshd /root/.ssh && $SUDO chmod 700 /root/.ssh
_n=0
for K in "${SSH_PUBKEYS[@]}"; do
  $SUDO grep -qF "$K" /root/.ssh/authorized_keys 2>/dev/null || echo "$K" | $SUDO tee -a /root/.ssh/authorized_keys >/dev/null
  info "authorize: $(printf '%s' "$K" | awk '{print $1"  …  "$NF}')"; _n=$((_n+1))
done
$SUDO chmod 600 /root/.ssh/authorized_keys
ok "authorized $_n key(s) in /root/.ssh/authorized_keys"
$SUDO sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
$SUDO sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config 2>/dev/null || true
$SUDO ssh-keygen -A >/dev/null 2>&1 || true
if [ "$HAS_SYSTEMD" = 1 ]; then
  $SUDO systemctl enable --now ssh >/dev/null 2>&1 || $SUDO systemctl enable --now sshd >/dev/null 2>&1 || true
else
  $SUDO service ssh start >/dev/null 2>&1 || true
  pgrep -x sshd >/dev/null 2>&1 || $SUDO /usr/sbin/sshd 2>/dev/null || true
fi
sleep 1
SSHD_PORT=$($SUDO /usr/sbin/sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); [ -z "$SSHD_PORT" ] && SSHD_PORT=22
if pgrep -x sshd >/dev/null 2>&1; then ok "sshd running, listening on :$SSHD_PORT"; else warn "sshd NOT running (debug: $SUDO /usr/sbin/sshd -T)"; fi

log "2/3  frpc — install + config"
FRPC=/usr/local/bin/frpc
if [ ! -x "$FRPC" ]; then
  _tgz="frp_${FRP_VER}_linux_${FARCH}.tar.gz"; _rel="fatedier/frp/releases/download/v$FRP_VER/$_tgz"
  # China-Windows egress often can't reach github/gh-proxy fast — try several
  # mirrors with per-try timeouts and fail over until one yields a real binary.
  for _u in \
    "https://ghfast.top/https://github.com/$_rel" \
    "https://gh-proxy.com/https://github.com/$_rel" \
    "https://ghproxy.net/https://github.com/$_rel" \
    "https://github.com/$_rel"; do
    info "downloading frpc v$FRP_VER ($FARCH) from ${_u%%/https*}${_u##*//github.com} ..."
    if curl -fsSL -m 90 --retry 1 -o "/tmp/$_tgz" "$_u" 2>/dev/null && tar xzf "/tmp/$_tgz" -C /tmp 2>/dev/null \
       && [ -x "/tmp/frp_${FRP_VER}_linux_${FARCH}/frpc" ]; then
      $SUDO install -m0755 "/tmp/frp_${FRP_VER}_linux_${FARCH}/frpc" "$FRPC"; break
    fi
    warn "  that mirror failed, trying next ..."
  done
  [ -x "$FRPC" ] || warn "frpc download failed from all mirrors"
else
  info "frpc already installed, reusing"
fi
[ -x "$FRPC" ] && ok "frpc $($FRPC -v 2>/dev/null) at $FRPC" || warn "frpc missing"
$SUDO tee /etc/frpc-wsl.toml >/dev/null <<EOF
serverAddr = "$FRP_SERVER"
serverPort = $FRP_PORT
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "$FRP_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SSHD_PORT
remotePort = $FRP_REMOTE_PORT
EOF
ok "wrote /etc/frpc-wsl.toml (localPort $SSHD_PORT → gateway :$FRP_REMOTE_PORT)"

log "3/3  frpc — start + persist"
# FRP_FOREGROUND=1 → run frpc in the FOREGROUND (exec) and never return. On WSL2
# this is the reliable persistence: a Windows-side `wsl.exe` process (e.g. a
# Task-Scheduler task, or `start /b`) stays blocked on this frpc, which keeps the
# distro's VM alive — plain nohup/setsid processes get reaped when WSL2 tears the
# distro down after the launching wsl.exe exits.
if [ "${FRP_FOREGROUND:-0}" = 1 ]; then
  ok "FRP_FOREGROUND=1 → frpc in foreground (holds the WSL distro alive)"
  info "connect: ssh -p $FRP_REMOTE_PORT root@$FRP_SERVER"
  exec "$FRPC" -c /etc/frpc-wsl.toml
fi
if [ "$HAS_SYSTEMD" = 1 ]; then
  $SUDO tee /etc/systemd/system/frpc-wsl.service >/dev/null <<EOF
[Unit]
Description=cicy WSL frpc reverse SSH tunnel
After=network-online.target ssh.service
Wants=network-online.target
[Service]
ExecStart=$FRPC -c /etc/frpc-wsl.toml
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload && $SUDO systemctl enable --now frpc-wsl >/dev/null 2>&1
  sleep 2
  $SUDO systemctl is-active --quiet frpc-wsl && ok "frpc-wsl.service active (auto-restart, survives wsl --shutdown via systemd)" || warn "frpc-wsl.service not active — journalctl -u frpc-wsl"
else
  $SUDO pkill -f 'frpc -c /etc/frpc-wsl.toml' 2>/dev/null || true
  $SUDO sh -c "setsid nohup '$FRPC' -c /etc/frpc-wsl.toml >/var/log/frpc-wsl.log 2>&1 &" || true
  sleep 2
  pgrep -f 'frpc -c /etc/frpc-wsl.toml' >/dev/null && ok "frpc running (nohup; log /var/log/frpc-wsl.log)" || warn "frpc not running — see /var/log/frpc-wsl.log"
  warn "no systemd → NOT auto-started on boot. To persist across reboots, add a Windows"
  info "Task Scheduler task (Triggers: At log on) that runs:"
  info "  wsl.exe -d \"\$(cat /etc/wsl.distroname 2>/dev/null || echo Ubuntu)\" -u root -- bash -lc '\\"
  info "    service ssh start; setsid nohup $FRPC -c /etc/frpc-wsl.toml >/var/log/frpc-wsl.log 2>&1 &'"
fi

printf '\n\033[1;35m════════════════════════════════════════════════\033[0m\n'
ok "WSL exposed. Connect from anywhere:"
info "ssh -p $FRP_REMOTE_PORT root@$FRP_SERVER"
info "(tunnel: this WSL :$SSHD_PORT ─frpc→ $FRP_SERVER:$FRP_PORT ─→ public :$FRP_REMOTE_PORT)"
