#!/usr/bin/env bash
# cicy-cloudshell.sh — run cicy-code in Docker on Google Cloud Shell + expose the
# host over frp. NO domain/port/secret is in this file — they ALL come from
# ~/config.ini (bash-sourced), so this can be public + curl|bash'd:
#
#   curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh | bash
#
# Re-run on every Cloud Shell restart. ~/config.ini persists on /home.
set -euo pipefail

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }

# ── config: everything (secrets + keys + ports) comes from ~/config.ini ──────
CONFIG="${CICY_CONFIG:-$HOME/config.ini}"
if [ -f "$CONFIG" ]; then
  set -a; . "$CONFIG"; set +a
  ok "loaded config: $CONFIG"
else
  echo "❌ 缺少配置文件 $CONFIG"
  echo "   建一个,至少含:CFT_TOKEN= / GW_API_KEY= / FRP_TOKEN= / SSH_PUBKEYS=(…)"
  echo "   模板见 https://github.com/cicy-ai/cicy-tools (config.ini.example)"
  exit 1
fi
# required from config.ini — secrets AND all domain/port (nothing hardcoded here)
: "${CFT_TOKEN:?CFT_TOKEN 未在 config.ini 设置}"
: "${GW_API_KEY:?GW_API_KEY 未在 config.ini 设置}"
: "${FRP_TOKEN:?FRP_TOKEN 未在 config.ini 设置}"
: "${CFT_HOST:?CFT_HOST 未在 config.ini 设置}"
: "${GW_ENDPOINT:?GW_ENDPOINT 未在 config.ini 设置}"
: "${FRP_SERVER:?FRP_SERVER 未在 config.ini 设置}"
: "${FRP_PORT:?FRP_PORT 未在 config.ini 设置}"
: "${FRP_REMOTE_PORT:?FRP_REMOTE_PORT 未在 config.ini 设置}"
# non-sensitive defaults (overridable in config.ini)
IMAGE="${IMAGE:-docker.io/cicybot/cicy-code:latest}"
NAME="${NAME:-cicy}"
PERSIST="${PERSIST:-$HOME/cicy-persist}"
FRP_NAME="${FRP_NAME:-cloudshell-host-ssh}"
SSHD_PORT="${SSHD_PORT:-2222}"   # our OWN sshd — Cloud Shell's managed :22 reads a
                                 # central authorized_keys it periodically rewrites.
# authorized keys: from config.ini (bash array) or a built-in fallback
if [ -z "${SSH_PUBKEYS+x}" ]; then
  SSH_PUBKEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKWMycBp5+3owB6EFEl8vKGDe8CkRvGeBaHCldVWZSb5 linux-w10125"
  )
fi

command -v docker >/dev/null || { echo "docker not found"; exit 1; }

CICY_UID=1001; CICY_GID=1001
# cicy is BOTH the numeric owner of the persisted dirs (uid 1001, matches the
# in-container user) AND the stable SSH login for this host. Recreated every run
# on purpose: Cloud Shell does not persist /etc/passwd.
log "host cicy user (stable SSH login for this Cloud Shell)"
if id -u cicy >/dev/null 2>&1; then
  echo "  cicy already exists (uid $(id -u cicy)) — enforcing login-capable state"
else
  sudo groupadd -g "$CICY_GID" cicy 2>/dev/null || true
  sudo useradd  -u "$CICY_UID" -g "$CICY_GID" -m -d /home/cicy -s /bin/bash cicy 2>/dev/null || true
  echo "  created cicy (uid $CICY_UID)"
fi
sudo usermod -s /bin/bash -d /home/cicy cicy 2>/dev/null || true
sudo mkdir -p /home/cicy && sudo chown cicy:cicy /home/cicy
sudo passwd -u cicy >/dev/null 2>&1 || true
echo "cicy:$(openssl rand -base64 18 2>/dev/null || echo "cicy${RANDOM}${RANDOM}${RANDOM}")" | sudo chpasswd 2>/dev/null || true
echo "  shell=$(getent passwd cicy | cut -d: -f7)  home=$(getent passwd cicy | cut -d: -f6)  passwd=$(sudo passwd -S cicy 2>/dev/null | awk '{print $2}') (want P/NP, not L)"
echo "cicy ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-cicy >/dev/null && sudo chmod 440 /etc/sudoers.d/90-cicy
ok "sudo: NOPASSWD"
sudo install -d -m700 -o cicy -g cicy /home/cicy/.ssh
for K in "${SSH_PUBKEYS[@]}"; do
  sudo grep -qF "$K" /home/cicy/.ssh/authorized_keys 2>/dev/null || echo "$K" | sudo tee -a /home/cicy/.ssh/authorized_keys >/dev/null
done
sudo chmod 600 /home/cicy/.ssh/authorized_keys && sudo chown -R cicy:cicy /home/cicy/.ssh
ok "authorized_keys: $(sudo grep -c . /home/cicy/.ssh/authorized_keys 2>/dev/null || echo 0) key(s) in ~cicy/.ssh"

mkdir -p "$PERSIST/claude" "$PERSIST/npm-global" "$PERSIST/ssh" "$PERSIST/local" "$HOME/go" 2>/dev/null || true
chmod 777 "$HOME/go" 2>/dev/null || sudo chmod 777 "$HOME/go" 2>/dev/null || true
# projects + cicy-ai live at /home/cicy/* — the SAME absolute path as INSIDE the
# container (whose home IS /home/cicy) — and are mounted there. So a nested
# `docker run -v ~/projects:...` from inside the container works against the HOST
# daemon (docker-outside-of-docker) with no path translation. The Cloud Shell
# user reaches them via a ~ symlink. (go stays under the Cloud Shell home.)
for _d in projects cicy-ai; do
  sudo mkdir -p "/home/cicy/$_d"
  if [ -d "$HOME/$_d" ] && [ ! -L "$HOME/$_d" ]; then   # migrate an old real dir once
    sudo cp -an "$HOME/$_d/." "/home/cicy/$_d/" 2>/dev/null || true; sudo rm -rf "$HOME/$_d"
  fi
  sudo chown "$CICY_UID:$CICY_GID" "/home/cicy/$_d" 2>/dev/null || true
  sudo chmod 777 "/home/cicy/$_d" 2>/dev/null || true
  ln -sfn "/home/cicy/$_d" "$HOME/$_d"
done
# ssh dir may be owned by cicy(1001) from a prior run — need sudo, and never abort
sudo chmod 700 "$PERSIST/ssh" 2>/dev/null || chmod 700 "$PERSIST/ssh" 2>/dev/null || true
# CLAUDE_CONFIG_DIR fix (single-file bind-mount of .claude.json fails atomic
# writes → re-login). Migrate legacy home-root copy into the .claude dir once.
[ -s "$PERSIST/claude/.claude.json" ] || cp "$PERSIST/claude.json" "$PERSIST/claude/.claude.json" 2>/dev/null || true
[ -s "$PERSIST/claude/.claude.json" ] || echo '{}' >"$PERSIST/claude/.claude.json"
sudo chown -R "$CICY_UID:$CICY_GID" "$PERSIST" 2>/dev/null || true

log "docker container"
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ] \
   && docker exec "$NAME" sh -lc 'curl -fsS http://127.0.0.1:8008/api/health' >/dev/null 2>&1; then
  ok "container '$NAME' already running & healthy — skipping pull/recreate"
else
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  image present locally — skipping pull"
  else
    echo "  pulling $IMAGE (progress below; first pull on a fresh VM can take a few min) ..."
    timeout 600 docker pull "$IMAGE" || warn "pull slow/failed — tip: set a mirror, e.g. IMAGE=\"mirror.gcr.io/cicybot/cicy-code:latest\" in ~/config.ini, or configure /etc/docker/daemon.json registry-mirrors"
  fi
  echo "  removing old container '$NAME' ..."; timeout 30 docker rm -f "$NAME" >/dev/null 2>&1 || warn "rm timed out / no old container"
  docker_args=()
  if [ -S /var/run/docker.sock ]; then
    docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    sock_gid="$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)"
    [ "$sock_gid" != "0" ] && docker_args+=(--group-add "$sock_gid")
  else
    warn "/var/run/docker.sock not found — docker-in-container disabled"
  fi
  docker run -d --name "$NAME" --restart unless-stopped \
    "${docker_args[@]}" \
    -v "/home/cicy/cicy-ai:/home/cicy/cicy-ai" \
    -v "$PERSIST/claude:/home/cicy/.claude" \
    -v "/home/cicy/projects:/home/cicy/projects" \
    -v "$HOME/go:/home/cicy/go" \
    -v "$PERSIST/npm-global:/home/cicy/.npm-global" \
    -v "$PERSIST/ssh:/home/cicy/.ssh" \
    -v "$PERSIST/local:/home/cicy/.local" \
    -e "CLAUDE_CONFIG_DIR=/home/cicy/.claude" \
    -e "CICY_CFT_TOKEN=$CFT_TOKEN" \
    -e "CICY_CFT_HOST=$CFT_HOST" \
    -e "CICY_CFT_NAME=$CFT_HOST" \
    -e "CICY_AI_GATEWAY_LLM_ENDPOINT=$GW_ENDPOINT" \
    -e "CICY_AI_GATEWAY_LLM_API_KEY=$GW_API_KEY" \
    "$IMAGE" >/dev/null
  ok "container started — stable hostname: https://$CFT_HOST"
fi

echo "  waiting for cicy-code health ..."
_up=""
for _ in $(seq 1 60); do
  docker exec "$NAME" sh -lc 'curl -fsS http://127.0.0.1:8008/api/health' >/dev/null 2>&1 && { _up=1; break; }
  sleep 2
done
[ -n "$_up" ] && ok "cicy-code healthy" || warn "cicy-code health timed out (120s) — check: docker logs $NAME"
TOKEN="$(docker exec "$NAME" sh -lc 'node -p "require(process.env.HOME+\"/cicy-ai/global.json\").api_token" 2>/dev/null' 2>/dev/null || true)"

# docker-outside-of-docker: give the container a docker CLI that drives the HOST
# daemon via the mounted socket (cicy is already in the socket group via
# --group-add, so no sudo needed). The binary persists on ~/cicy-ai/bin; the
# /usr/local/bin symlink is on the ephemeral overlay, so recreate it each run.
DKR_VER=27.3.1
docker exec "$NAME" sh -lc "[ -x ~/cicy-ai/bin/docker ] || { curl -fsSL -m60 https://download.docker.com/linux/static/stable/x86_64/docker-${DKR_VER}.tgz | tar -C /tmp -xz docker/docker && install -m0755 /tmp/docker/docker ~/cicy-ai/bin/docker; }" 2>/dev/null || true
docker exec -u 0 "$NAME" ln -sf /home/cicy/cicy-ai/bin/docker /usr/local/bin/docker 2>/dev/null || true
if docker exec "$NAME" docker ps >/dev/null 2>&1; then
  ok "docker CLI in container (docker-outside-of-docker → host daemon)"
else
  warn "docker-in-container CLI not ready (socket/group?)"
fi

# Go toolchain in the container. ~/go is a host↔container mount, so both the
# toolchain (~/go/sdk/go = GOROOT, auto-detected) and GOPATH (default ~/go)
# persist there. Only the /usr/local/bin symlink is ephemeral → redo each run.
GO_VER=1.25.0
docker exec "$NAME" sh -lc "[ -x ~/go/sdk/go/bin/go ] || { mkdir -p ~/go/sdk && curl -fsSL -m120 https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz | tar -C ~/go/sdk -xz; }" 2>/dev/null || true
docker exec -u 0 "$NAME" sh -lc 'ln -sf /home/cicy/go/sdk/go/bin/go /usr/local/bin/go; ln -sf /home/cicy/go/sdk/go/bin/gofmt /usr/local/bin/gofmt' 2>/dev/null || true
if docker exec "$NAME" go version >/dev/null 2>&1; then
  ok "go $(docker exec "$NAME" go version 2>/dev/null | awk '{print $3}') in container (GOPATH ~/go, persisted)"
else
  warn "go not ready in container"
fi

log "own sshd on :$SSHD_PORT + frp ($FRP_REMOTE_PORT)"
sudo mkdir -p /run/sshd
sudo tee /etc/ssh/sshd_config.cicy >/dev/null <<EOF
Port $SSHD_PORT
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile /home/cicy/.ssh/authorized_keys
StrictModes no
UsePAM no
PidFile /run/sshd-cicy.pid
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
sudo pkill -F /run/sshd-cicy.pid 2>/dev/null || true
sudo pkill -f 'sshd_config.cicy' 2>/dev/null || true
sleep 1
if sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.cicy 2>/dev/null && { sleep 1; pgrep -f 'sshd_config.cicy' >/dev/null 2>&1; }; then
  ok "own sshd listening on :$SSHD_PORT (reads ~cicy/.ssh/authorized_keys)"
else
  warn "own sshd failed to start — check: sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.cicy -d"
fi
FRPC="/home/cicy/cicy-ai/bin/frpc"
if [ -x "$FRPC" ]; then
  echo "  frpc: reusing $FRPC ($("$FRPC" -v 2>/dev/null || echo '?'))"
else
  V=0.68.1; echo "  frpc: downloading v$V ..."
  { curl -fsSL "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v$V/frp_${V}_linux_amd64.tar.gz" | tar xz -C /tmp \
    && mkdir -p "$HOME/.local/bin" && install -m0755 "/tmp/frp_${V}_linux_amd64/frpc" "$HOME/.local/bin/frpc" && FRPC="$HOME/.local/bin/frpc"; } || true
fi
cat > "$HOME/frpc-host.toml" <<EOF
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
pkill -f 'frpc-host.toml' 2>/dev/null || true
if [ -x "$FRPC" ]; then
  nohup "$FRPC" -c "$HOME/frpc-host.toml" >"$HOME/frpc-host.log" 2>&1 & disown 2>/dev/null || true
  sleep 3
  pgrep -f 'frpc-host.toml' >/dev/null 2>&1 && ok "frpc running (pid $(pgrep -f 'frpc-host.toml' | head -1))" || warn "frpc failed to stay up — check ~/frpc-host.log"
  grep -qi 'start proxy success' "$HOME/frpc-host.log" 2>/dev/null && ok "proxy '$FRP_NAME' registered on gateway" || warn "proxy not confirmed — tail ~/frpc-host.log"
else
  warn "frpc binary missing — host SSH tunnel NOT started"
fi

echo
echo "============================================================"
echo "  Public:   https://$CFT_HOST/?token=${TOKEN:-<see global.json>}"
echo "  Host SSH: ssh -p $FRP_REMOTE_PORT cicy@$FRP_SERVER   (then: sudo docker exec -it cicy bash)"
echo "  logs:     docker logs -f $NAME"
echo "  stop:     docker rm -f $NAME"
echo "============================================================"
