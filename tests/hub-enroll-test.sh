#!/usr/bin/env bash
# The Colab installer joins CiCy Hub directly: a fresh runtime enrols through a
# sponsor token, a credential restored from the config repo is reused while the
# hub still accepts it, and a rejected one is re-enrolled.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cicy-hub-enroll.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"; [[ -n "${HUB_PID:-}" ]] && kill "$HUB_PID" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# the agent shell may carry a MITM proxy for outbound HTTP; the mock hub is loopback
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

bash -n "$ROOT/colab-cicy-code.sh" || fail "colab-cicy-code.sh does not parse"
grep -q ': > "\$runtime_args_file"' "$ROOT/colab-cicy-code.sh" || fail "runtime args must be empty (no --cft quick tunnel)"
grep -qE 'trycloudflare|https://cicy-ai\.com' "$ROOT/colab-cicy-code.sh" && fail "installer still references cicy-cloud or the quick tunnel"

# mock hub: /api/enroll issues a token per call; /api/instances accepts only tokens it issued
cat > "$TEST_ROOT/hub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
issued = set(); calls = {"enroll": 0}
class H(BaseHTTPRequestHandler):
    def _json(self, code, body):
        data = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        if self.path != "/api/enroll": return self._json(404, {"error": "not_found"})
        if self.headers.get("Authorization") != "Bearer sponsor-token": return self._json(401, {"error": "unauthorized"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        calls["enroll"] += 1; tok = "issued-%d" % calls["enroll"]; issued.add(tok)
        self._json(200, {"success": True, "token": tok, "owner": "owner@example.com", "instanceId": body["instanceId"],
                         "proxyHost": body["name"].replace("_", "-") + ".hub.example"})
    def do_GET(self):
        if self.path != "/api/instances": return self._json(404, {"error": "not_found"})
        tok = self.headers.get("Authorization", "").replace("Bearer ", "")
        if tok not in issued and tok != "restored-good": return self._json(401, {"error": "unauthorized"})
        self._json(200, {"instances": [{"instanceId": "code-restored0000000000000000000000000000", "proxyHost": "colab-limeng.hub.example"}]})
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(srv.server_port)); srv.serve_forever()
PY
python3 "$TEST_ROOT/hub.py" "$TEST_ROOT/port" & HUB_PID=$!
for _ in $(seq 1 50); do [[ -s "$TEST_ROOT/port" ]] && break; sleep 0.1; done
ORIGIN="http://127.0.0.1:$(cat "$TEST_ROOT/port")"

# load only the function under test
eval "$(sed -n '/^enroll_hub_instance() {/,/^}/p' "$ROOT/colab-cicy-code.sh")"
CONTENT_DIR="$TEST_ROOT"; HUB_HOST_FILE="$TEST_ROOT/hub-host"; CICY_EMAIL=owner@example.com; RESET_CLOUD_INSTANCE=0
DEV="$TEST_ROOT/db/cloud-device.json"

# 1. fresh runtime: enrol with the sponsor token, write a hub-mode credential
enroll_hub_instance "$DEV" colab_limeng "$ORIGIN" sponsor-token >/dev/null || fail "fresh enrol failed"
[[ "$(jq -r .mode "$DEV")" == "hub" ]] || fail "credential mode is not hub"
[[ "$(jq -r .token "$DEV")" == "issued-1" ]] || fail "credential token not taken from enrol"
[[ "$(jq -r .cloud_origin "$DEV")" == "$ORIGIN" ]] || fail "credential origin is not the hub"
[[ "$(jq -r .team_id "$DEV")" == "colab_limeng" ]] || fail "credential team wrong"
[[ "$(jq -r .instance_id "$DEV")" =~ ^code-[a-f0-9]{36}$ ]] || fail "instance id not generated: $(jq -r .instance_id "$DEV")"
[[ "$(stat -c %a "$DEV")" == "600" ]] || fail "credential not 0600"
[[ "$(cat "$HUB_HOST_FILE")" == "colab-limeng.hub.example" ]] || fail "hub host not recorded"

# 2. restored credential still accepted by the hub → reused, no sponsor needed, same instance id
jq '.token="restored-good" | .instance_id="code-restored0000000000000000000000000000"' "$DEV" > "$DEV.new" && mv "$DEV.new" "$DEV"
enroll_hub_instance "$DEV" colab_limeng "$ORIGIN" "" >/dev/null || fail "reuse of a valid credential failed"
[[ "$(jq -r .token "$DEV")" == "restored-good" ]] || fail "valid credential was replaced"
[[ "$(jq -r .instance_id "$DEV")" == "code-restored0000000000000000000000000000" ]] || fail "instance id changed on reuse"

# 3. restored credential rejected by the hub → re-enrol keeps the instance id (same hostname)
jq '.token="restored-bad"' "$DEV" > "$DEV.new" && mv "$DEV.new" "$DEV"
enroll_hub_instance "$DEV" colab_limeng "$ORIGIN" sponsor-token >/dev/null || fail "re-enrol after rejection failed"
[[ "$(jq -r .token "$DEV")" == "issued-2" ]] || fail "rejected credential was not re-enrolled"
[[ "$(jq -r .instance_id "$DEV")" == "code-restored0000000000000000000000000000" ]] || fail "re-enrol did not keep the instance id"

# 4. rejected credential and no sponsor token → clear failure, credential left in place
jq '.token="restored-bad"' "$DEV" > "$DEV.new" && mv "$DEV.new" "$DEV"
if enroll_hub_instance "$DEV" colab_limeng "$ORIGIN" "" >/dev/null 2>"$TEST_ROOT/err"; then fail "enrol without sponsor must fail"; fi
grep -q "CICY_HUB_TOKEN is not set" "$TEST_ROOT/err" || fail "missing-sponsor error not reported"

# 5. team change moves the old identity aside and enrols anew
enroll_hub_instance "$DEV" colab_other "$ORIGIN" sponsor-token >/dev/null || fail "team change enrol failed"
[[ "$(jq -r .team_id "$DEV")" == "colab_other" ]] || fail "team not switched"
ls "$TEST_ROOT"/cloud-device.*.previous.json >/dev/null 2>&1 || fail "old identity was not moved aside"

echo "PASS: hub-enroll-test"
