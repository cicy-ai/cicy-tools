#!/usr/bin/env bash
# colab-frp-ssh.sh — expose THIS Google Colab runtime's SSH through a frp gateway.
# All connection params come IN via env (the Colab cell / caller passes them) —
# no gateway domain or port is hardcoded here.
#
# Run from a Colab cell:
#   FRP_TOKEN=… FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… \
#     bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-frp-ssh.sh)
#
# ⚠ Colab is EPHEMERAL: nothing persists. Re-run every new runtime. The tunnel
#   dies when the runtime recycles (~90min idle / ~12h max). Google's ToS frowns
#   on long-lived tunnels/servers on Colab — it may kill the runtime.
set -uo pipefail

# required — passed IN via env by the Colab cell / caller (no domain/port here) —
: "${FRP_SERVER:?FRP_SERVER 未设置(由 cell/caller 传入)}"
: "${FRP_PORT:?FRP_PORT 未设置}"
: "${FRP_REMOTE_PORT:?FRP_REMOTE_PORT 未设置}"
: "${FRP_TOKEN:?FRP_TOKEN 未设置(用 Colab cell 从 Secrets 注入)}"
FRP_NAME="${FRP_NAME:-colab-ssh}"               # frp proxy name (unique per runtime)
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

printf '\033[1;35m══════════ CiCy Colab SSH tunnel setup ══════════\033[0m\n'
_GPU=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
info "host:    $(hostname)   ($(uname -m), $(nproc 2>/dev/null || echo '?') cpu, $(free -h 2>/dev/null | awk '/^Mem:/{print $2}') ram)"
info "gpu:     ${_GPU:-none — CPU runtime(要显卡去「修改运行时类型」选 T4 GPU)}"
info "gateway: $FRP_SERVER:$FRP_PORT   proxy: $FRP_NAME   public-port: $FRP_REMOTE_PORT"

log "1/3  sshd — install + authorize keys + start"
info "apt: installing openssh-server (quiet) ..."
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
$SUDO ssh-keygen -A >/dev/null 2>&1 || true          # host keys (fresh runtime has none)
$SUDO service ssh start >/dev/null 2>&1 || true
pgrep -x sshd >/dev/null 2>&1 || $SUDO /usr/sbin/sshd 2>/dev/null || true
sleep 1
SSHD_PORT=$($SUDO /usr/sbin/sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
[ -z "$SSHD_PORT" ] && SSHD_PORT=22
info "sshd config: $($SUDO /usr/sbin/sshd -T 2>/dev/null | grep -iE '^(port|permitrootlogin|pubkeyauthentication) ' | tr '\n' ' ')"
_LISTEN=$( { $SUDO ss -tlnp 2>/dev/null || $SUDO netstat -tlnp 2>/dev/null; } | grep ":$SSHD_PORT " | head -1)
if pgrep -x sshd >/dev/null 2>&1; then
  ok "sshd running, listening on :$SSHD_PORT"
  [ -n "$_LISTEN" ] && info "listen: $_LISTEN"
else
  warn "sshd NOT running — login will be refused (debug: /usr/sbin/sshd -T)"
fi

log "2/3  frpc — install"
FRPC=/usr/local/bin/frpc
if [ ! -x "$FRPC" ]; then
  info "downloading frpc v$FRP_VER (via gh-proxy) ..."
  { curl -fsSL "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v$FRP_VER/frp_${FRP_VER}_linux_amd64.tar.gz" | tar xz -C /tmp \
    && $SUDO install -m0755 "/tmp/frp_${FRP_VER}_linux_amd64/frpc" "$FRPC"; } || warn "frpc download/install failed"
else
  info "frpc already installed, reusing"
fi
[ -x "$FRPC" ] && ok "frpc $($FRPC -v 2>/dev/null) at $FRPC" || warn "frpc missing"
cat > /root/frpc-colab.toml <<EOF
serverAddr = "$FRP_SERVER"
serverPort = $FRP_PORT
auth.method = "token"
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "$FRP_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SSHD_PORT
remotePort = $FRP_REMOTE_PORT
EOF
info "config: /root/frpc-colab.toml  ( :$SSHD_PORT → $FRP_SERVER:$FRP_REMOTE_PORT , token ${FRP_TOKEN:0:6}… )"

log "3/3  tunnel — start frpc + register on gateway"
pkill -f 'frpc-colab.toml' 2>/dev/null && info "killed a previous frpc" || true
setsid nohup "$FRPC" -c /root/frpc-colab.toml >/root/frpc-colab.log 2>&1 &
info "waiting for gateway registration ..."
sleep 4
echo "    ┄┄ frpc log (last 8 lines) ┄┄"
tail -n 8 /root/frpc-colab.log 2>/dev/null | sed $'s/^/      /'
echo "    ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
if grep -qi 'start proxy success' /root/frpc-colab.log 2>/dev/null; then
  ok "tunnel REGISTERED (frpc pid $(pgrep -f frpc-colab.toml | head -1))"
elif grep -qi 'login to server success' /root/frpc-colab.log 2>/dev/null; then
  warn "connected to gateway but proxy not confirmed — port $FRP_REMOTE_PORT already taken? check the log above"
else
  warn "tunnel NOT confirmed — token/gateway/port issue; see log above or: tail -f /root/frpc-colab.log"
fi

echo
printf '\033[1;32m═══════════════════════ READY ═══════════════════════\033[0m\n'
echo "  SSH:  ssh -p $FRP_REMOTE_PORT root@$FRP_SERVER"
echo "  GPU:  ${_GPU:-none (CPU only — pick a T4 GPU runtime for experiments)}"
echo "  log:  tail -f /root/frpc-colab.log"
echo "  ⚠ Colab is ephemeral — re-run this cell after every new runtime."
printf '\033[1;32m═════════════════════════════════════════════════════\033[0m\n'
