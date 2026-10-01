#!/usr/bin/env bash
# Run the real installer with offline downloads and service stubs. Mount and
# network namespaces keep every production path and the host network isolated.
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
  unset FASTPROXY_REPO FASTPROXY_NODE_VERSION FASTPROXY_LISTEN FASTPROXY_ADMIN_USER
  unset SSH_CONNECTION
  touch "$CASE_DIR/requests.log" "$CASE_DIR/services.log"
  ARGS=()
  RELEASE=v1.2.3
  case "$SCENARIO" in
    latest) ;;
    explicit) ARGS=(--version v1.2.2); RELEASE=v1.2.2 ;;
    invalid)
      if bash "$ROOT/scripts/install.sh" --version 20.04 --check > "$CASE_DIR/output" 2>&1; then
        echo 'An invalid release version passed --check'; exit 1
      fi
      awk '/版本格式/ {found=1} END {exit !found}' "$CASE_DIR/output"
      [[ ! -s "$CASE_DIR/requests.log" && ! -s "$CASE_DIR/services.log" ]]
      echo "$OS: invalid version rejected before installation: PASS"
      exit 0 ;;
    checksum) export CORRUPT_CHECKSUM=true ;;
    *) exit 1 ;;
  esac
  export RELEASE
  if [[ "$SCENARIO" == checksum ]]; then
    if bash "$ROOT/scripts/install.sh" > "$CASE_DIR/output" 2>&1; then
      echo 'A bad release checksum was accepted'; exit 1
    fi
    awk '/发布包校验失败/ {found=1} END {exit !found}' "$CASE_DIR/output"
    [[ ! -e /opt/fastproxy && ! -e /etc/fastproxy && ! -s "$CASE_DIR/services.log" ]]
    echo "$OS: bad checksum rejected before installation: PASS"
    exit 0
  fi
  if ! bash "$ROOT/scripts/install.sh" "${ARGS[@]}" > "$CASE_DIR/output" 2>&1; then
    cat "$CASE_DIR/output"; exit 1
  fi
  awk -v expected="https://github.com/bunnya33/fastproxy/releases/download/$RELEASE/fastproxy-$RELEASE.tar.gz" \
    '$0 == expected {found=1} END {exit !found}' "$CASE_DIR/requests.log"
  if [[ "$SCENARIO" == explicit ]]; then
    awk '/releases\/latest/ {bad=1} END {exit bad}' "$CASE_DIR/requests.log"
  else
    awk '/releases\/latest/ {found=1} END {exit !found}' "$CASE_DIR/requests.log"
  fi
  [[ -x /usr/local/bin/fastproxy && -x /opt/fastproxy/runtime/bin/node ]]
  [[ $(/opt/fastproxy/runtime/bin/node --version) == v24.11.1 ]]
  [[ $(stat -c %a /etc/fastproxy/fastproxy.env) == 600 ]]
  cmp "$ROOT/scripts/fastproxy.service" /etc/systemd/system/fastproxy.service
  awk '/^start fastproxy$/ {found=1} END {exit !found}' "$CASE_DIR/services.log"
  cp /etc/fastproxy/fastproxy.env "$CASE_DIR/original.env"
  printf '%s\n' '{"revision":7,"rules":[]}' > /var/lib/fastproxy/state.json
  cp /var/lib/fastproxy/state.json "$CASE_DIR/original-state.json"
  # Repeat through the same installer with different defaults: existing config
  # and saved rules must survive, and the existing service must be restarted.
  export FASTPROXY_ADMIN_PASSWORD=different-regression-password
  if ! bash "$ROOT/scripts/install.sh" "${ARGS[@]}" --listen 0.0.0.0:9090 > "$CASE_DIR/update-output" 2>&1; then
    cat "$CASE_DIR/update-output"; exit 1
  fi
  cmp "$CASE_DIR/original.env" /etc/fastproxy/fastproxy.env
  cmp "$CASE_DIR/original-state.json" /var/lib/fastproxy/state.json
  awk '/^stop fastproxy$/ {found=1} END {exit !found}' "$CASE_DIR/services.log"
  [[ ! -e /opt/fastproxy.previous ]]
  echo "$OS: $SCENARIO release installation and update: PASS"
  exit 0
fi

FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
mkdir -p "$FIXTURES/bin" "$FIXTURES/app/apps/server/dist" "$FIXTURES/app/apps/server/public" \
  "$FIXTURES/app/node_modules/fastify" "$FIXTURES/app/scripts" "$FIXTURES/node/bin"
touch "$FIXTURES/app/apps/server/dist/main.js" "$FIXTURES/app/apps/server/public/index.html"
cp "$ROOT/scripts/start" "$FIXTURES/app/start"
cp "$ROOT/scripts/fastproxy" "$ROOT/scripts/fastproxy.service" "$FIXTURES/app/scripts/"
cat > "$FIXTURES/node/bin/node" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --version ]] || exit 1
echo v24.11.1
STUB
chmod +x "$FIXTURES/node/bin/node"
tar -czf "$FIXTURES/app.tar.gz" -C "$FIXTURES/app" .
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
cat > "$FIXTURES/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
[[ $1 == -p && $2 == /etc/sysctl.d/90-fastproxy.conf ]]
STUB
cat > "$FIXTURES/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CASE_DIR/services.log"
case "$1" in
  is-active) [[ -f "$CASE_DIR/active" ]] ;;
  start) [[ -f /opt/fastproxy/apps/server/dist/main.js && -f /etc/fastproxy/fastproxy.env ]]; touch "$CASE_DIR/active" ;;
  stop) rm -f "$CASE_DIR/active" ;;
  daemon-reload|enable) ;;
  *) exit 1 ;;
esac
STUB
cat > "$FIXTURES/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
URL=''
OUTPUT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT=$2; shift 2 ;;
    --proto|--max-time|--unix-socket) shift 2 ;;
    -*) shift ;;
    *) URL=$1; shift ;;
  esac
done
echo "$URL" >> "$CASE_DIR/requests.log"
case "$URL" in
  https://api.github.com/repos/bunnya33/fastproxy/releases/latest) printf '{"tag_name":"%s"}\n' "$RELEASE" ;;
  "https://github.com/bunnya33/fastproxy/releases/download/$RELEASE/fastproxy-$RELEASE.tar.gz") cp "$FIXTURES/app.tar.gz" "$OUTPUT" ;;
  "https://github.com/bunnya33/fastproxy/releases/download/$RELEASE/SHA256SUMS")
    SUM=$(sha256sum "$FIXTURES/app.tar.gz"); SUM=${SUM%% *}
    if [[ ${CORRUPT_CHECKSUM:-false} == true ]]; then SUM=$(printf '%064d' 0); fi
    printf '%s  fastproxy-%s.tar.gz\n' "$SUM" "$RELEASE" > "$OUTPUT" ;;
  https://nodejs.org/dist/index.json) echo '[{"version":"v24.11.1","lts":"Krypton"}]' ;;
  https://nodejs.org/dist/v24.11.1/node-v24.11.1-linux-x64.tar.xz) cp "$FIXTURES/node.tar.xz" "$OUTPUT" ;;
  https://nodejs.org/dist/v24.11.1/SHASUMS256.txt)
    SUM=$(sha256sum "$FIXTURES/node.tar.xz"); SUM=${SUM%% *}
    printf '%s  node-v24.11.1-linux-x64.tar.xz\n' "$SUM" > "$OUTPUT" ;;
  http://localhost/healthz) [[ -f "$CASE_DIR/active" ]]; echo '{"ok":true}' ;;
  *) echo "Unexpected download: $URL" >&2; exit 1 ;;
esac
STUB
chmod +x "$FIXTURES/bin/"*
# /usr/bin/awk can point through /etc/alternatives, which is hidden by the
# isolated /etc. Resolve it before mounting the fixture operating-system data.
ln -s "$(readlink -f "$(command -v awk)")" "$FIXTURES/bin/awk"
for OS in ubuntu debian; do
  for SCENARIO in latest explicit invalid checksum; do
    unshare --mount --net --fork --propagation private bash "$0" --namespace "$FIXTURES" "$OS" "$SCENARIO"
  done
done
