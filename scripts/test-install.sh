#!/usr/bin/env bash
# Isolated source installations. --real compiles the actual Vue/TypeScript
# checkout and starts the installed server with real Node.js and HAProxy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo 'Run with sudo'; exit 1; }

if [[ ${1:-} == --namespace ]]; then
  [[ $(readlink "/proc/$$/ns/mnt") != $(readlink /proc/1/ns/mnt) && \
     $(readlink "/proc/$$/ns/net") != $(readlink /proc/1/ns/net) ]] || {
    echo 'Refuse to test in the host mount or network namespace'; exit 1
  }
  FIXTURES=$2
  OS=$3
  SCENARIO=$4
  CASE_DIR="$FIXTURES/$OS-$SCENARIO"
  mkdir -p "$CASE_DIR"/{etc/systemd/system,etc/sysctl.d,opt,var-lib,run/systemd/system,local-bin}
  mount --bind "$CASE_DIR/etc" /etc
  mount --bind "$CASE_DIR/opt" /opt
  mount --bind "$CASE_DIR/var-lib" /var/lib
  mount --bind "$CASE_DIR/run" /run
  mount --bind "$CASE_DIR/local-bin" /usr/local/bin
  cp "$FIXTURES/$OS.os-release" /etc/os-release
  export PATH="$FIXTURES/bin:$PATH" FIXTURES CASE_DIR
  export FASTPROXY_ADMIN_PASSWORD=installer-regression-password
  unset FASTPROXY_REPO FASTPROXY_NODE_VERSION FASTPROXY_LISTEN FASTPROXY_ADMIN_USER SSH_CONNECTION
  touch "$CASE_DIR/requests.log" "$CASE_DIR/services.log" "$CASE_DIR/git.log" "$CASE_DIR/npm.log"
  trap 'if [[ -f "$CASE_DIR/active" ]]; then systemctl stop fastproxy >/dev/null 2>&1 || true; fi' EXIT
  if [[ "$REAL_INSTALL" == true ]]; then ip link set lo up; fi
  INSTALL_ARGS=()
  case "$SCENARIO" in
    local|remote|migration_failure) ;;
    explicit) INSTALL_ARGS=(--version v1.2.2) ;;
    latest) INSTALL_ARGS=(--version latest) ;;
    invalid)
      if bash "$ROOT/scripts/install.sh" --version 20.04 --check > "$CASE_DIR/output" 2>&1; then
        echo 'An invalid source version passed --check'; exit 1
      fi
      awk '/版本格式/ {found=1} END {exit !found}' "$CASE_DIR/output"
      [[ ! -s "$CASE_DIR/requests.log" && ! -s "$CASE_DIR/services.log" ]]
      echo "$OS: invalid source version rejected: PASS"
      exit 0 ;;
    checksum) export CORRUPT_CHECKSUM=true ;;
    *) exit 1 ;;
  esac
  run_install() {
    if [[ "$SCENARIO" == local ]]; then
      bash "$FIXTURES/source/scripts/install.sh" "$@"
    else
      # stdin is the same entry point as curl ... | bash; it cannot infer a
      # checkout from BASH_SOURCE and must fetch source with git.
      bash -s -- "${INSTALL_ARGS[@]}" "$@" < "$ROOT/scripts/install.sh"
    fi
  }
  if [[ "$SCENARIO" == checksum ]]; then
    if run_install > "$CASE_DIR/output" 2>&1; then echo 'A bad Node checksum was accepted'; exit 1; fi
    awk '/Node.js 校验失败/ {found=1} END {exit !found}' "$CASE_DIR/output"
    [[ ! -e /opt/fastproxy && ! -e /etc/fastproxy && ! -s "$CASE_DIR/services.log" ]]
    echo "$OS: Node checksum rejected before installation: PASS"
    exit 0
  fi
  if ! run_install > "$CASE_DIR/output" 2>&1; then cat "$CASE_DIR/output"; cat "$CASE_DIR/server.log" 2>/dev/null || true; exit 1; fi
  case "$SCENARIO" in
    local) [[ ! -s "$CASE_DIR/git.log" ]] ;;
    remote|migration_failure) awk '/--branch main / {found=1} END {exit !found}' "$CASE_DIR/git.log" ;;
    explicit) awk '/--branch v1.2.2 / {found=1} END {exit !found}' "$CASE_DIR/git.log" ;;
    latest) awk '/--branch v1.2.3 / {found=1} END {exit !found}' "$CASE_DIR/git.log" ;;
  esac
  [[ -x /usr/local/bin/fastproxy && -x /opt/fastproxy/runtime/bin/node ]]
  [[ $(/opt/fastproxy/runtime/bin/node --version) == "$NODE_TEST_VERSION" ]]
  [[ $(stat -c %a /etc/fastproxy/fastproxy.env) == 600 ]]
  [[ ! -e /opt/fastproxy/.env && ! -e /opt/fastproxy/apps/server/data ]]
  cmp "$ROOT/scripts/fastproxy.service" /etc/systemd/system/fastproxy.service
  cp /etc/fastproxy/fastproxy.env "$CASE_DIR/original.env"
  if [[ "$REAL_INSTALL" == true ]]; then
    [[ ! -d /opt/fastproxy/node_modules/typescript && ! -d /opt/fastproxy/node_modules/vue ]]
    "$FIXTURES/real-curl" -fsS http://127.0.0.1:8080/ > "$CASE_DIR/web.html"
    awk '/FastProxy/ {found=1} END {exit !found}' "$CASE_DIR/web.html"
    "$FIXTURES/real-curl" -fsS --unix-socket /run/fastproxy/control.sock -X POST -H 'Content-Type: application/json' \
      --data-binary '{"revision":0,"rule":{"id":"","name":"source install","protocol":"tcp","listen_ip":"0.0.0.0","listen_port":18000,"target_ip":"10.250.2.2","target_port":19000,"enabled":true}}' \
      http://localhost/api/rules > "$CASE_DIR/rule.json"
    ss -ltn | awk '/:18000 / {found=1} END {exit !found}'
    /usr/local/bin/fastproxy list > "$CASE_DIR/menu.txt"
    awk '/source install/ {found=1} END {exit !found}' "$CASE_DIR/menu.txt"
  else
    printf '%s\n' '{"schema_version":2,"revision":7,"forwarding":true,"rules":[],"updated_at":null}' > /var/lib/fastproxy/state.json
    awk '/^run build$/ {found=1} END {exit !found}' "$CASE_DIR/npm.log"
    awk '/--omit=dev/ {found=1} END {exit !found}' "$CASE_DIR/npm.log"
  fi
  if [[ "$REAL_INSTALL" == true || "$SCENARIO" == migration_failure ]]; then
    # Simulate an installed nftables version. The actual new backend must
    # migrate this state on update while retaining passwords and endpoints.
    sed 's/FASTPROXY_MODE=haproxy/FASTPROXY_MODE=nftables/; s/FASTPROXY_HAPROXY_BINARY=.*/FASTPROXY_NFT_BINARY=\/usr\/sbin\/nft/' /etc/fastproxy/fastproxy.env > "$CASE_DIR/legacy.env"
    cp "$CASE_DIR/legacy.env" /etc/fastproxy/fastproxy.env
    jq '.schema_version=1 | .rules |= map(.protocol="both") | .rules += [{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"legacy UDP",protocol:"udp",listen_ip:"0.0.0.0",listen_port:18003,target_ip:"10.250.2.2",target_port:19003,enabled:true}]' \
      /var/lib/fastproxy/state.json > "$CASE_DIR/legacy-state.json"
    cp "$CASE_DIR/legacy-state.json" /var/lib/fastproxy/state.json
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-fastproxy.conf
    touch "$CASE_DIR/legacy-table"
    if [[ "$SCENARIO" == migration_failure ]]; then
      export FAIL_START=true
      if run_install > "$CASE_DIR/migration-output" 2>&1; then echo 'Failed migration was accepted'; exit 1; fi
      cmp "$CASE_DIR/legacy.env" /etc/fastproxy/fastproxy.env
      cmp "$CASE_DIR/legacy-state.json" /var/lib/fastproxy/state.json
      [[ -d /opt/fastproxy.failed && -f "$CASE_DIR/active" ]]
      echo "$OS: failed migration restores old program, engine config and rules: PASS"
      exit 0
    fi
  fi
  cp /var/lib/fastproxy/state.json "$CASE_DIR/original-state.json"
  export FASTPROXY_ADMIN_PASSWORD=different-regression-password
  if ! run_install --listen 0.0.0.0:9090 > "$CASE_DIR/update-output" 2>&1; then
    cat "$CASE_DIR/update-output"; cat "$CASE_DIR/server.log" 2>/dev/null || true; exit 1
  fi
  if [[ "$REAL_INSTALL" == true ]]; then
    diff <(sort "$CASE_DIR/original.env") <(sort /etc/fastproxy/fastproxy.env)
    cmp "$CASE_DIR/legacy.env" /etc/fastproxy/fastproxy.env.nftables-backup
    cmp <(jq -S . "$CASE_DIR/legacy-state.json") <(jq -S . /var/lib/fastproxy/state.nftables-backup.json)
    jq -e '.schema_version == 2 and .revision == 2 and .rules[0].protocol == "tcp" and .rules[0].enabled and .rules[1].protocol == "udp" and (.rules[1].enabled | not)' /var/lib/fastproxy/state.json >/dev/null
    [[ ! -f /etc/sysctl.d/90-fastproxy.conf && ! -f "$CASE_DIR/legacy-table" ]]
  else
    cmp "$CASE_DIR/original.env" /etc/fastproxy/fastproxy.env
    cmp "$CASE_DIR/original-state.json" /var/lib/fastproxy/state.json
  fi
  awk '/^stop fastproxy$/ {found=1} END {exit !found}' "$CASE_DIR/services.log"
  [[ ! -e /opt/fastproxy.previous ]]
  if [[ "$REAL_INSTALL" == true ]]; then
    /usr/local/bin/fastproxy list > "$CASE_DIR/menu.txt"
    awk '/source install/ {found=1} END {exit !found}' "$CASE_DIR/menu.txt"
    ss -ltn | awk '/:18000 / {found=1} END {exit !found}'
    systemctl stop fastproxy
    if ss -ltn | awk '/:18000 / {found=1} END {exit !found}'; then echo 'Stopped service left a TCP listener'; exit 1; fi
  else
    cp "$CASE_DIR/services.log" "$CASE_DIR/original-services.log"
    cp /opt/fastproxy/apps/server/dist/main.js "$CASE_DIR/original-main.js"
    export FAIL_BUILD=true
    if run_install > "$CASE_DIR/failure-output" 2>&1; then echo 'A failed build succeeded'; exit 1; fi
    cmp "$CASE_DIR/original.env" /etc/fastproxy/fastproxy.env
    cmp "$CASE_DIR/original-state.json" /var/lib/fastproxy/state.json
    cmp "$CASE_DIR/original-services.log" "$CASE_DIR/services.log"
    cmp "$CASE_DIR/original-main.js" /opt/fastproxy/apps/server/dist/main.js
  fi
  echo "$OS: $SCENARIO source build, installation and preserved update (real=$REAL_INSTALL): PASS"
  exit 0
fi

REAL_INSTALL=false
if [[ ${1:-} == --real ]]; then REAL_INSTALL=true; elif [[ $# -gt 0 ]]; then echo 'Usage: test-install.sh [--real]'; exit 1; fi
export REAL_INSTALL
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
mkdir -p "$FIXTURES/bin" "$FIXTURES/source/apps/server" "$FIXTURES/source/apps/web" "$FIXTURES/source/scripts" "$FIXTURES/node/bin"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$ROOT/README.md" "$ROOT/LICENSE" "$FIXTURES/source/"
cp -a "$ROOT/apps/server/src" "$ROOT/apps/server/package.json" "$ROOT/apps/server/tsconfig.json" "$FIXTURES/source/apps/server/"
cp -a "$ROOT/apps/web/src" "$ROOT/apps/web/public" "$ROOT/apps/web/package.json" "$ROOT/apps/web/tsconfig.json" \
  "$ROOT/apps/web/vite.config.ts" "$ROOT/apps/web/index.html" "$FIXTURES/source/apps/web/"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/start" "$ROOT/scripts/fastproxy" "$ROOT/scripts/fastproxy.service" "$FIXTURES/source/scripts/"
mkdir -p "$FIXTURES/source/apps/server/data"
touch "$FIXTURES/source/.env" "$FIXTURES/source/apps/server/data/private-data"
if [[ "$REAL_INSTALL" == true ]]; then
  NODE_BIN=${FASTPROXY_TEST_NODE:-$(command -v node)}
  RUNTIME=$(dirname "$(dirname "$(readlink -f "$NODE_BIN")")")
  NODE_TEST_VERSION=$("$NODE_BIN" --version)
  [[ "$NODE_TEST_VERSION" =~ ^v24\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a Linux Node.js 24 runtime'; exit 1; }
  cp -a "$RUNTIME/." "$FIXTURES/node/"
  export npm_config_cache="$FIXTURES/npm-cache" npm_config_userconfig="$FIXTURES/npmrc"
  touch "$FIXTURES/npmrc"
  cp -a "$FIXTURES/source" "$FIXTURES/warmup"
  # Warm an isolated npm cache before removing network access. The installation
  # itself still executes real npm ci, frontend/server builds and production ci.
  (cd "$FIXTURES/warmup" && PATH="$RUNTIME/bin:$PATH" npm ci --include=dev --no-audit --no-fund)
  export npm_config_offline=true
else
  NODE_TEST_VERSION=v24.11.1
  cat > "$FIXTURES/node/bin/node" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --version ]] || exit 1
echo v24.11.1
STUB
  cat > "$FIXTURES/node/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CASE_DIR/npm.log"
case "$1" in
  ci) mkdir -p node_modules/fastify ;;
  run)
    [[ $2 == build && ${FAIL_BUILD:-false} == false ]]
    mkdir -p apps/server/dist apps/server/public
    echo 'compiled server' > apps/server/dist/main.js
    echo FastProxy > apps/server/public/index.html ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$FIXTURES/node/bin/"*
fi
export NODE_TEST_VERSION
tar -cJf "$FIXTURES/node.tar.xz" -C "$FIXTURES" node
cat > "$FIXTURES/ubuntu.os-release" <<'OS'
ID=ubuntu
VERSION_ID="20.04"
VERSION="20.04.5 LTS (Focal Fossa)"
PRETTY_NAME="Ubuntu 20.04.5 LTS"
OS
cat > "$FIXTURES/debian.os-release" <<'OS'
ID=debian
VERSION_ID="12"
VERSION="12 (bookworm)"
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
OS
cat > "$FIXTURES/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$FIXTURES/bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 1 ;; esac
STUB
cat > "$FIXTURES/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CASE_DIR/git.log"
[[ $1 == clone && $* == *https://github.com/bunnya33/fastproxy.git* ]]
cp -a "$FIXTURES/source" "${!#}"
STUB
cat > "$FIXTURES/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
echo 'HAProxy installer must not change sysctl' >&2
exit 1
STUB
cat > "$FIXTURES/bin/nft" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'list table ip fastproxy' || $* == 'delete table ip fastproxy' ]]
[[ -f "$CASE_DIR/legacy-table" ]]
if [[ $1 == delete ]]; then rm "$CASE_DIR/legacy-table"; fi
STUB
cat > "$FIXTURES/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CASE_DIR/services.log"
case "$1" in
  is-active) [[ -f "$CASE_DIR/active" ]] ;;
  start)
    if [[ ${FAIL_START:-false} == true && ! -f "$CASE_DIR/failure-consumed" ]]; then touch "$CASE_DIR/failure-consumed"; exit 1; fi
    [[ -f /opt/fastproxy/apps/server/dist/main.js && -f /etc/fastproxy/fastproxy.env ]]
    if [[ "$REAL_INSTALL" == true ]]; then
      set -a
      source /etc/fastproxy/fastproxy.env
      set +a
      /opt/fastproxy/start < /dev/null >> "$CASE_DIR/server.log" 2>&1 &
      echo "$!" > "$CASE_DIR/pid"
    fi
    touch "$CASE_DIR/active" ;;
  stop)
    if [[ "$REAL_INSTALL" == true && -f "$CASE_DIR/active" ]]; then
      PID=$(cat "$CASE_DIR/pid")
      kill "$PID" 2>/dev/null || true
      for ((i=0;i<100;i++)); do
        [[ -S /run/fastproxy/control.sock ]] || break
        sleep 0.1
      done
    fi
    rm -f "$CASE_DIR/active" ;;
  daemon-reload|enable) ;;
  *) exit 1 ;;
esac
STUB
cat > "$FIXTURES/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
CURL_ARGS=("$@")
URL=''
OUTPUT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT=$2; shift 2 ;;
    --proto|--max-time|--unix-socket|-X|-H|--data-binary) shift 2 ;;
    -*) shift ;;
    *) URL=$1; shift ;;
  esac
done
echo "$URL" >> "$CASE_DIR/requests.log"
case "$URL" in
  https://api.github.com/repos/bunnya33/fastproxy/releases/latest) echo '{"tag_name":"v1.2.3"}' ;;
  https://nodejs.org/dist/index.json) printf '[{"version":"%s","lts":"Krypton"}]\n' "$NODE_TEST_VERSION" ;;
  "https://nodejs.org/dist/$NODE_TEST_VERSION/node-$NODE_TEST_VERSION-linux-x64.tar.xz") cp "$FIXTURES/node.tar.xz" "$OUTPUT" ;;
  "https://nodejs.org/dist/$NODE_TEST_VERSION/SHASUMS256.txt")
    SUM=$(sha256sum "$FIXTURES/node.tar.xz"); SUM=${SUM%% *}
    if [[ ${CORRUPT_CHECKSUM:-false} == true ]]; then SUM=$(printf '%064d' 0); fi
    printf '%s  node-%s-linux-x64.tar.xz\n' "$SUM" "$NODE_TEST_VERSION" > "$OUTPUT" ;;
  http://localhost/*)
    if [[ "$REAL_INSTALL" == true ]]; then exec "$FIXTURES/real-curl" "${CURL_ARGS[@]}"; fi
    [[ "$URL" == http://localhost/healthz && -f "$CASE_DIR/active" ]]; echo '{"ok":true}' ;;
  *) echo "Unexpected download: $URL" >&2; exit 1 ;;
esac
STUB
chmod +x "$FIXTURES/bin/"*
# Resolve tools whose symlinks pass through /etc/alternatives before hiding /etc.
ln -s "$(readlink -f "$(command -v awk)")" "$FIXTURES/bin/awk"
ln -s "$(readlink -f "$(command -v curl)")" "$FIXTURES/real-curl"
for OS in ubuntu debian; do
  if [[ "$REAL_INSTALL" == true ]]; then SCENARIOS=(local); else SCENARIOS=(local remote explicit latest invalid checksum migration_failure); fi
  for SCENARIO in "${SCENARIOS[@]}"; do
    unshare --mount --net --fork --propagation private bash "$0" --namespace "$FIXTURES" "$OS" "$SCENARIO"
  done
done
