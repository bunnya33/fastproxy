#!/usr/bin/env bash
# Exercise the real unit's security settings in an isolated network namespace.
# No host firewall or permanent FastProxy installation is changed.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo'; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'systemd is required'; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NODE_BIN=${FASTPROXY_TEST_NODE:-$(command -v node)}
UNIT="fastproxy-smoke-$$"
UNIT_FILE="/run/systemd/system/$UNIT.service"
QA_DIR=$(mktemp -d /run/fastproxy-qa.XXXXXX)
HOLDER=''
cleanup() {
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  if [[ -n "$HOLDER" ]]; then kill "$HOLDER" 2>/dev/null || true; fi
  rm -rf "$QA_DIR"
}
trap cleanup EXIT
# ProtectHome must remain enabled even when the checkout or Node is in /home.
# Stage the built application and executable outside the protected directories.
mkdir -p "$QA_DIR/app/apps/server"
install -m 755 "$NODE_BIN" "$QA_DIR/node"
NODE_BIN="$QA_DIR/node"
cp -a "$ROOT/apps/server/dist" "$ROOT/apps/server/package.json" "$QA_DIR/app/apps/server/"
cp -a "$ROOT/node_modules" "$QA_DIR/app/"
if [[ -d "$ROOT/apps/server/node_modules" ]]; then cp -a "$ROOT/apps/server/node_modules" "$QA_DIR/app/apps/server/"; fi
APP_ROOT="$QA_DIR/app"
unshare --net "$NODE_BIN" -e 'setInterval(() => {}, 60000)' &
HOLDER=$!
for ((i=0; i<20; i++)); do
  if [[ $(readlink "/proc/$HOLDER/ns/net") != $(readlink /proc/1/ns/net) ]]; then break; fi
  sleep 0.1
done
[[ $(readlink "/proc/$HOLDER/ns/net") != $(readlink /proc/1/ns/net) ]] || { echo 'refuse host namespace'; exit 1; }
nsenter -t "$HOLDER" -n ip link set lo up
mkdir -p "$QA_DIR/data"
cat > "$QA_DIR/config.env" <<ENV
FASTPROXY_MODE=haproxy
FASTPROXY_LISTEN=127.0.0.1:8080
FASTPROXY_ADMIN_USER=admin
FASTPROXY_ADMIN_PASSWORD=systemd-smoke-test-password
FASTPROXY_DATA_DIR=$QA_DIR/data
FASTPROXY_SOCKET=/run/$UNIT/control.sock
FASTPROXY_HAPROXY_BINARY=/usr/sbin/haproxy
ENV
sed \
  -e "s|EnvironmentFile=.*|EnvironmentFile=$QA_DIR/config.env|" \
  -e "s|ExecStart=.*|ExecStart=$NODE_BIN $APP_ROOT/apps/server/dist/main.js|" \
  -e "s|WorkingDirectory=.*|WorkingDirectory=$APP_ROOT|" \
  -e "s|RuntimeDirectory=fastproxy$|RuntimeDirectory=$UNIT|" \
  -e '/^StateDirectory/d' \
  -e "s|ReadWritePaths=.*|ReadWritePaths=$QA_DIR /run/$UNIT|" \
  -e "/^PrivateTmp=/a NetworkNamespacePath=/proc/$HOLDER/ns/net" \
  "$ROOT/scripts/fastproxy.service" > "$UNIT_FILE"
systemd-analyze verify "$UNIT_FILE"
systemctl daemon-reload
systemctl start "$UNIT"
wait_ready() {
  for ((i=0; i<60; i++)); do
    if curl -fsS --max-time 2 --unix-socket "/run/$UNIT/control.sock" http://localhost/healthz >/dev/null 2>&1; then return; fi
    sleep 0.5
  done
  journalctl -u "$UNIT" -n 30 --no-pager
  systemctl status "$UNIT" --no-pager || true
  return 1
}
wait_ready
MAIN_PID=$(systemctl show "$UNIT" -p MainPID --value)
# CAP_NET_BIND_SERVICE is bit 10; CAP_NET_ADMIN (bit 12) must be absent.
CAP_BOUND=$(awk '/^CapBnd:/ {print $2}' "/proc/$MAIN_PID/status")
[[ $((16#$CAP_BOUND)) -eq 1024 ]]
curl -fsS --unix-socket "/run/$UNIT/control.sock" -X POST -H 'Content-Type: application/json' \
  --data-binary '{"revision":0,"rule":{"id":"","name":"systemd smoke","protocol":"tcp","listen_ip":"0.0.0.0","listen_port":18000,"target_ip":"10.250.2.2","target_port":19000,"enabled":true}}' \
  http://localhost/api/rules > "$QA_DIR/result.json"
"$NODE_BIN" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])); if(s.revision!==1||s.rules.length!==1) process.exit(1)' "$QA_DIR/result.json"
nsenter -t "$HOLDER" -n ss -ltn > "$QA_DIR/listeners.txt"
awk '/:18000 / {found=1} END {exit !found}' "$QA_DIR/listeners.txt"
env FASTPROXY_SOCKET="/run/$UNIT/control.sock" bash "$ROOT/scripts/fastproxy" list > "$QA_DIR/menu-list.txt"
awk '/systemd smoke/ {found=1} END {exit !found}' "$QA_DIR/menu-list.txt"
# Disable through the API, then edit through the actual terminal menu. A disabled
# rule must remain disabled after an edit (jq's // treats false as missing).
jq '{revision:.revision,rule:(.rules[0] | .enabled=false)}' "$QA_DIR/result.json" > "$QA_DIR/update.json"
RULE_ID=$(jq -r '.rule.id' "$QA_DIR/update.json")
curl -fsS --unix-socket "/run/$UNIT/control.sock" -X PUT -H 'Content-Type: application/json' \
  --data-binary "@$QA_DIR/update.json" "http://localhost/api/rules/$RULE_ID" > "$QA_DIR/result.json"
printf -v CONSOLE_COMMAND 'env FASTPROXY_SOCKET=%q bash %q' "/run/$UNIT/control.sock" "$ROOT/scripts/fastproxy"
printf '4\n1\n\n\n18001\n\n\n0\n' | SHELL=/bin/bash script -q -e -c "$CONSOLE_COMMAND" /dev/null > "$QA_DIR/menu-edit.txt"
curl -fsS --unix-socket "/run/$UNIT/control.sock" http://localhost/api/status > "$QA_DIR/result.json"
jq -e '.state.revision == 3 and .state.rules[0].listen_port == 18001 and .state.rules[0].enabled == false' "$QA_DIR/result.json" >/dev/null
systemctl restart "$UNIT"
wait_ready
curl -fsS --unix-socket "/run/$UNIT/control.sock" http://localhost/api/status > "$QA_DIR/result.json"
"$NODE_BIN" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])); if(s.state.revision!==3||!s.runtime.healthy) process.exit(1)' "$QA_DIR/result.json"
# Kill only the managed HAProxy worker and verify systemd recovers the manager.
MAIN_PID=$(systemctl show "$UNIT" -p MainPID --value)
WORKER_PID=$(jq -r '.runtime.pid' "$QA_DIR/result.json")
kill -KILL "$WORKER_PID"
RECOVERED=false
for ((i=0; i<60; i++)); do
  NEW_PID=$(systemctl show "$UNIT" -p MainPID --value)
  if [[ "$NEW_PID" != 0 && "$NEW_PID" != "$MAIN_PID" ]]; then RECOVERED=true; break; fi
  sleep 0.5
done
[[ "$RECOVERED" == true ]]
wait_ready
curl -fsS --unix-socket "/run/$UNIT/control.sock" http://localhost/api/status > "$QA_DIR/result.json"
jq -e '.state.revision == 3 and .runtime.healthy and .state.rules[0].enabled == false' "$QA_DIR/result.json" >/dev/null
systemctl stop "$UNIT"
if nsenter -t "$HOLDER" -n ss -ltn | awk '/:1800[01] / {found=1} END {exit !found}'; then echo 'listener was not removed'; exit 1; fi
echo 'systemd startup, root-only API, terminal menu, capability restrictions, worker crash recovery, rule restoration and stop: PASS'
