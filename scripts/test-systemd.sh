#!/usr/bin/env bash
# Exercise the real unit's security settings in an isolated network namespace.
# No host nftables table or permanent FastProxy installation is created.
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
unshare --net "$NODE_BIN" -e 'setInterval(() => {}, 60000)' &
HOLDER=$!
for ((i=0; i<20; i++)); do
  if [[ $(readlink "/proc/$HOLDER/ns/net") != $(readlink /proc/1/ns/net) ]]; then break; fi
  sleep 0.1
done
[[ $(readlink "/proc/$HOLDER/ns/net") != $(readlink /proc/1/ns/net) ]] || { echo 'refuse host namespace'; exit 1; }
nsenter -t "$HOLDER" -n ip link set lo up
nsenter -t "$HOLDER" -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p "$QA_DIR/data"
cat > "$QA_DIR/config.env" <<ENV
FASTPROXY_MODE=nftables
FASTPROXY_LISTEN=127.0.0.1:8080
FASTPROXY_ADMIN_USER=admin
FASTPROXY_ADMIN_PASSWORD=systemd-smoke-test-password
FASTPROXY_DATA_DIR=$QA_DIR/data
FASTPROXY_SOCKET=/run/$UNIT/control.sock
FASTPROXY_NFT_BINARY=/usr/sbin/nft
ENV
sed \
  -e "s|EnvironmentFile=.*|EnvironmentFile=$QA_DIR/config.env|" \
  -e "s|ExecStart=.*|ExecStart=$NODE_BIN $ROOT/apps/server/dist/main.js|" \
  -e "s|WorkingDirectory=.*|WorkingDirectory=$ROOT|" \
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
curl -fsS --unix-socket "/run/$UNIT/control.sock" -X POST -H 'Content-Type: application/json' \
  --data-binary '{"revision":0,"rule":{"id":"","name":"systemd smoke","protocol":"both","listen_ip":"0.0.0.0","listen_port":18000,"target_ip":"10.250.2.2","target_port":19000,"enabled":true}}' \
  http://localhost/api/rules > "$QA_DIR/result.json"
"$NODE_BIN" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])); if(s.revision!==1||s.rules.length!==1) process.exit(1)' "$QA_DIR/result.json"
nsenter -t "$HOLDER" -n nft list table ip fastproxy > "$QA_DIR/nft.txt"
awk '/dnat to 10.250.2.2:19000/ {count++} END {exit count!=2}' "$QA_DIR/nft.txt"
env FASTPROXY_SOCKET="/run/$UNIT/control.sock" bash "$ROOT/scripts/fastproxy" list > "$QA_DIR/menu-list.txt"
awk '/systemd smoke/ {found=1} END {exit !found}' "$QA_DIR/menu-list.txt"
# Disable through the API, then edit through the actual terminal menu. A disabled
# rule must remain disabled after an edit (jq's // treats false as missing).
jq '{revision:.revision,rule:(.rules[0] | .enabled=false)}' "$QA_DIR/result.json" > "$QA_DIR/update.json"
RULE_ID=$(jq -r '.rule.id' "$QA_DIR/update.json")
curl -fsS --unix-socket "/run/$UNIT/control.sock" -X PUT -H 'Content-Type: application/json' \
  --data-binary "@$QA_DIR/update.json" "http://localhost/api/rules/$RULE_ID" > "$QA_DIR/result.json"
printf -v CONSOLE_COMMAND 'env FASTPROXY_SOCKET=%q bash %q' "/run/$UNIT/control.sock" "$ROOT/scripts/fastproxy"
printf '4\n1\n\n\n\n18001\n\n\n0\n' | SHELL=/bin/bash script -q -e -c "$CONSOLE_COMMAND" /dev/null > "$QA_DIR/menu-edit.txt"
curl -fsS --unix-socket "/run/$UNIT/control.sock" http://localhost/api/status > "$QA_DIR/result.json"
jq -e '.state.revision == 3 and .state.rules[0].listen_port == 18001 and .state.rules[0].enabled == false' "$QA_DIR/result.json" >/dev/null
systemctl restart "$UNIT"
wait_ready
curl -fsS --unix-socket "/run/$UNIT/control.sock" http://localhost/api/status > "$QA_DIR/result.json"
"$NODE_BIN" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])); if(s.state.revision!==3||!s.runtime.healthy) process.exit(1)' "$QA_DIR/result.json"
systemctl stop "$UNIT"
if nsenter -t "$HOLDER" -n nft list table ip fastproxy >/dev/null 2>&1; then echo 'table was not removed'; exit 1; fi
echo 'systemd startup, root-only API, real terminal menu editing, capability restrictions, rule restoration and graceful stop: PASS'
