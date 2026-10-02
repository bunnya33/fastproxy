#!/usr/bin/env bash
# Build and install Node.js/TypeScript + Vue directly from source. No Docker.
set -euo pipefail

REPO=${FASTPROXY_REPO:-bunnya33/fastproxy}
RELEASE_VERSION=main
SOURCE=''
REMOTE_REQUESTED=false
LISTEN=${FASTPROXY_LISTEN:-127.0.0.1:8080}
ADMIN_USER=${FASTPROXY_ADMIN_USER:-admin}
ADMIN_PASSWORD=${FASTPROXY_ADMIN_PASSWORD:-}
NODE_VERSION=${FASTPROXY_NODE_VERSION:-}
INSTALL_ROOT=/opt/fastproxy
CHECK_ONLY=false

usage() {
  cat <<'HELP'
FastProxy 源码编译安装 / 更新（Debian 12+、Ubuntu 20.04+，systemd）
  bash scripts/install.sh                编译脚本所在的源码仓库
  bash install.sh --source /path/fastproxy
  bash install.sh --repo OWNER/REPO [--version v0.2.0]
选项：
  --version main|latest|v0.2.0  拉取 main、最新发布标签或指定标签
  --listen 127.0.0.1:8080   管理后台监听地址（首次安装）
  --user admin             管理用户名（首次安装）
  --check                  只检查环境，不安装
  --help                   帮助
已有安装更新时保留密码、管理地址、规则与审计记录。
HELP
}
die() { echo "错误：$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--version|--source|--listen|--user)
      [[ $# -ge 2 ]] || die "$1 缺少参数"
      case "$1" in
        --repo) REPO=$2; REMOTE_REQUESTED=true ;;
        --version) RELEASE_VERSION=$2; REMOTE_REQUESTED=true ;;
        --source) SOURCE=$2 ;;
        --listen) LISTEN=$2 ;;
        --user) ADMIN_USER=$2 ;;
      esac
      shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done
[[ $(uname -s) == Linux ]] || die '仅支持 Linux'
[[ $EUID -eq 0 ]] || die '请使用 sudo bash 安装'
[[ -d /run/systemd/system ]] || die '需要正在运行的 systemd'
# shellcheck source=/dev/null
source /etc/os-release
# os-release defines VERSION for the operating system; keep the application
# release in RELEASE_VERSION so both the default and --version survive sourcing.
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die '首版安装器支持 Debian / Ubuntu'
OS_MAJOR=${VERSION_ID:-0}
OS_MAJOR=${OS_MAJOR%%.*}
[[ "$OS_MAJOR" =~ ^[0-9]+$ ]] || die '无法识别系统版本'
if [[ "$ID" == debian ]]; then [[ "$OS_MAJOR" -ge 12 ]] || die '需要 Debian 12 或更高版本'; fi
if [[ "$ID" == ubuntu ]]; then [[ "$OS_MAJOR" -ge 20 ]] || die '需要 Ubuntu 20.04 或更高版本'; fi
case $(uname -m) in x86_64) ARCH=x64 ;; aarch64|arm64) ARCH=arm64 ;; *) die '仅支持 amd64 / arm64' ;; esac
[[ "$LISTEN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || die '监听地址格式应为 IPv4:端口'
PORT=${LISTEN##*:}
[[ $((10#$PORT)) -ge 1 && $((10#$PORT)) -le 65535 ]] || die '管理端口应为 1–65535'
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '仓库格式应为 OWNER/REPO'
[[ "$RELEASE_VERSION" == main || "$RELEASE_VERSION" == latest || "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '版本格式应为 main、latest 或 v0.2.0'
[[ -z "$SOURCE" || "$REMOTE_REQUESTED" == false ]] || die '--source 不能与 --repo / --version 同时使用'
# A repository invocation builds its checkout. A script downloaded or piped
# through curl fetches source from Git; it does not depend on release archives.
if [[ -z "$SOURCE" && "$REMOTE_REQUESTED" == false && -f ${BASH_SOURCE[0]:-} ]]; then
  SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  if [[ -f "$SCRIPT_ROOT/package.json" && -f "$SCRIPT_ROOT/package-lock.json" ]]; then SOURCE=$SCRIPT_ROOT; fi
fi
validate_source() {
  local entry
  for entry in package.json package-lock.json apps/server/package.json apps/server/tsconfig.json apps/server/src \
    apps/web/package.json apps/web/tsconfig.json apps/web/vite.config.ts apps/web/index.html apps/web/src apps/web/public \
    scripts/start scripts/fastproxy scripts/fastproxy.service README.md LICENSE; do
    [[ -e "$SOURCE/$entry" ]] || die "源码不完整，缺少 $entry"
  done
}
if [[ -n "$SOURCE" ]]; then
  [[ -d "$SOURCE" ]] || die '源码目录不存在'
  SOURCE=$(realpath "$SOURCE")
  validate_source
fi
if [[ "$CHECK_ONLY" == true ]]; then
  echo "环境检查通过：${PRETTY_NAME:-Linux}，$ARCH，systemd；安装位置 $INSTALL_ROOT"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git jq haproxy xz-utils openssl libstdc++6
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ -z "$SOURCE" ]]; then
  if [[ "$RELEASE_VERSION" == latest ]]; then
    RELEASE_VERSION=$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name')
    [[ "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '未找到正式发布版本，请先创建 GitHub Release'
  fi
  echo "拉取源码：$REPO ($RELEASE_VERSION)"
  git clone --depth 1 --branch "$RELEASE_VERSION" "https://github.com/$REPO.git" "$TMP/source"
  SOURCE="$TMP/source"
  validate_source
fi
echo "编译源码：$SOURCE"
# Copy only build inputs. Keep checkout dependencies, demo data and credentials
# out of the installation; npm must resolve native dependencies on this server.
mkdir -p "$TMP/app/apps/server" "$TMP/app/apps/web" "$TMP/app/scripts"
cp "$SOURCE/package.json" "$SOURCE/package-lock.json" "$SOURCE/README.md" "$SOURCE/LICENSE" "$TMP/app/"
cp -a "$SOURCE/apps/server/src" "$SOURCE/apps/server/package.json" "$SOURCE/apps/server/tsconfig.json" "$TMP/app/apps/server/"
cp -a "$SOURCE/apps/web/src" "$SOURCE/apps/web/public" "$SOURCE/apps/web/package.json" "$SOURCE/apps/web/tsconfig.json" \
  "$SOURCE/apps/web/vite.config.ts" "$SOURCE/apps/web/index.html" "$TMP/app/apps/web/"
cp "$SOURCE/scripts/start" "$SOURCE/scripts/fastproxy" "$SOURCE/scripts/fastproxy.service" "$TMP/app/scripts/"
cp "$SOURCE/scripts/start" "$TMP/app/start"

# Use a private, verified runtime; do not alter the server's existing Node.js.
if [[ -z "$NODE_VERSION" ]]; then
  NODE_VERSION=$(curl -fsSL --proto '=https' --tlsv1.2 https://nodejs.org/dist/index.json | jq -r '[.[] | select(.version | test("^v24\\.[0-9]+\\.[0-9]+$")) | select(.lts != false)][0].version')
fi
[[ "$NODE_VERSION" =~ ^v24\.[0-9]+\.[0-9]+$ ]] || die '未找到有效的 Node.js 24 LTS 版本'
NODE_FILE="node-$NODE_VERSION-linux-$ARCH.tar.xz"
if [[ -x "$INSTALL_ROOT/runtime/bin/node" && $("$INSTALL_ROOT/runtime/bin/node" --version) == "$NODE_VERSION" ]]; then
  cp -a "$INSTALL_ROOT/runtime" "$TMP/app/runtime"
else
  NODE_BASE="https://nodejs.org/dist/$NODE_VERSION"
  curl -fsSL --proto '=https' --tlsv1.2 "$NODE_BASE/$NODE_FILE" -o "$TMP/$NODE_FILE"
  curl -fsSL --proto '=https' --tlsv1.2 "$NODE_BASE/SHASUMS256.txt" -o "$TMP/node-sha256.txt"
  (cd "$TMP" && awk -v file="$NODE_FILE" '$2 == file {print}' node-sha256.txt > node-selected.sha256 && [[ -s node-selected.sha256 ]] && sha256sum -c node-selected.sha256) || die 'Node.js 校验失败'
  mkdir -p "$TMP/app/runtime"
  tar -xJf "$TMP/$NODE_FILE" -C "$TMP/app/runtime" --strip-components=1
fi
"$TMP/app/runtime/bin/node" --version
(
  cd "$TMP/app"
  export PATH="$TMP/app/runtime/bin:$PATH"
  npm ci --include=dev --no-audit --no-fund
  npm run build
  npm ci --omit=dev --workspace @fastproxy/server --include-workspace-root=false --ignore-scripts --no-audit --no-fund
)
[[ -f "$TMP/app/apps/server/dist/main.js" && -f "$TMP/app/apps/server/public/index.html" && -d "$TMP/app/node_modules/fastify" ]] || die '编译产物不完整'

FIRST_INSTALL=false
mkdir -p /etc/fastproxy /var/lib/fastproxy
chmod 700 /etc/fastproxy /var/lib/fastproxy
if [[ ! -f /etc/fastproxy/fastproxy.env ]]; then
  FIRST_INSTALL=true
  ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(openssl rand -hex 18)}
  [[ ${#ADMIN_PASSWORD} -ge 12 ]] || die '管理密码至少 12 个字符'
  [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die '用户名应为 1–64 个字母、数字或 ._-'
  SSH_PORT=22
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r _ _ _ detected_ssh <<< "$SSH_CONNECTION"
    [[ "$detected_ssh" =~ ^[0-9]{1,5}$ ]] && SSH_PORT=$detected_ssh
  fi
  [[ "$PORT" != "$SSH_PORT" ]] || die '管理后台不能占用 SSH 端口'
  ESCAPED=${ADMIN_PASSWORD//\\/\\\\}; ESCAPED=${ESCAPED//\"/\\\"}
  [[ "$ESCAPED" != *$'\n'* && "$ESCAPED" != *$'\r'* ]] || die '密码不能包含换行'
  cat > /etc/fastproxy/fastproxy.env <<ENV
FASTPROXY_MODE=haproxy
FASTPROXY_LISTEN=$LISTEN
FASTPROXY_ADMIN_USER=$ADMIN_USER
FASTPROXY_ADMIN_PASSWORD="$ESCAPED"
FASTPROXY_COOKIE_SECURE=false
FASTPROXY_PROTECTED_PORTS=$SSH_PORT
FASTPROXY_DATA_DIR=/var/lib/fastproxy
FASTPROXY_SOCKET=/run/fastproxy/control.sock
FASTPROXY_HAPROXY_BINARY=/usr/sbin/haproxy
ENV
  chmod 600 /etc/fastproxy/fastproxy.env
fi
# Stop the old service only after the source build and runtime are ready.
[[ ! -e "$INSTALL_ROOT.previous" ]] || die "已有 $INSTALL_ROOT.previous，请先处理上次更新的备份"
[[ ! -e "$INSTALL_ROOT.failed" ]] || die "已有 $INSTALL_ROOT.failed，请先处理上次失败的版本"
WAS_ACTIVE=false
if systemctl is-active --quiet fastproxy; then WAS_ACTIVE=true; systemctl stop fastproxy; fi
MIGRATE_NFT=false
if awk '/^FASTPROXY_MODE="?nftables"?$/ {found=1} END {exit !found}' /etc/fastproxy/fastproxy.env; then
  MIGRATE_NFT=true
  cp -p /etc/fastproxy/fastproxy.env "$TMP/original.env"
  if [[ ! -f /etc/fastproxy/fastproxy.env.nftables-backup ]]; then cp -p /etc/fastproxy/fastproxy.env /etc/fastproxy/fastproxy.env.nftables-backup; fi
  if [[ -f /var/lib/fastproxy/state.json ]]; then cp -p /var/lib/fastproxy/state.json "$TMP/original-state.json"; fi
  # The old service removes its table on stop. Clean up only its dedicated
  # table if a previous crash left it behind; never change another firewall.
  if command -v nft >/dev/null && nft list table ip fastproxy >/dev/null 2>&1; then
    if ! nft delete table ip fastproxy; then
      [[ "$WAS_ACTIVE" == false ]] || systemctl start fastproxy
      die '旧 FastProxy 表清理失败，已停止迁移，请检查旧服务日志'
    fi
  fi
  awk '!/^FASTPROXY_MODE=/ && !/^FASTPROXY_NFT_BINARY=/ && !/^FASTPROXY_HAPROXY_BINARY=/' "$TMP/original.env" > "$TMP/haproxy.env"
  printf 'FASTPROXY_MODE=haproxy\nFASTPROXY_HAPROXY_BINARY=/usr/sbin/haproxy\n' >> "$TMP/haproxy.env"
  install -m 600 "$TMP/haproxy.env" /etc/fastproxy/fastproxy.env
fi
if [[ -d "$INSTALL_ROOT" ]]; then mv "$INSTALL_ROOT" "$INSTALL_ROOT.previous"; fi
mv "$TMP/app" "$INSTALL_ROOT"
chmod 755 "$INSTALL_ROOT/start" "$INSTALL_ROOT/scripts/fastproxy"
install -m 755 "$INSTALL_ROOT/scripts/fastproxy" /usr/local/bin/fastproxy
install -m 644 "$INSTALL_ROOT/scripts/fastproxy.service" /etc/systemd/system/fastproxy.service
systemctl daemon-reload
systemctl enable fastproxy >/dev/null
rollback() {
  systemctl stop fastproxy || true
  echo '启动失败，检查 journalctl -u fastproxy -n 50。' >&2
  if [[ -d "$INSTALL_ROOT.previous" ]]; then
    mv "$INSTALL_ROOT" "$INSTALL_ROOT.failed"
    mv "$INSTALL_ROOT.previous" "$INSTALL_ROOT"
    if [[ "$MIGRATE_NFT" == true ]]; then
      install -m 600 "$TMP/original.env" /etc/fastproxy/fastproxy.env
      if [[ -f "$TMP/original-state.json" ]]; then install -m 600 "$TMP/original-state.json" /var/lib/fastproxy/state.json; fi
    fi
    install -m 755 "$INSTALL_ROOT/scripts/fastproxy" /usr/local/bin/fastproxy
    install -m 644 "$INSTALL_ROOT/scripts/fastproxy.service" /etc/systemd/system/fastproxy.service
    systemctl daemon-reload
    [[ "$WAS_ACTIVE" == true ]] && systemctl start fastproxy
    echo "程序已回退，失败版本保留在 $INSTALL_ROOT.failed。" >&2
  fi
}
if ! systemctl start fastproxy; then rollback; exit 1; fi
READY=false
for ((i=0; i<15; i++)); do
  if curl -fsS --max-time 2 --unix-socket /run/fastproxy/control.sock http://localhost/healthz >/dev/null 2>&1; then READY=true; break; fi
  sleep 1
done
if [[ "$READY" != true ]]; then rollback; die '服务未就绪，已尝试回退；运行 sudo fastproxy logs 检查'; fi
if [[ -d "$INSTALL_ROOT.previous" ]]; then rm -rf "$INSTALL_ROOT.previous"; fi
if [[ "$MIGRATE_NFT" == true ]]; then
  if [[ -f /etc/sysctl.d/90-fastproxy.conf ]] && cmp -s /etc/sysctl.d/90-fastproxy.conf <(printf 'net.ipv4.ip_forward=1\n'); then rm /etc/sysctl.d/90-fastproxy.conf; fi
  echo '已迁移到 HAProxy；原配置和规则已备份。TCP 保留，both 改为 TCP，纯 UDP 规则保留为停用状态。'
fi
echo
echo 'FastProxy 已安装，数字菜单：sudo fastproxy'
if [[ "$FIRST_INSTALL" == true ]]; then
  printf '管理用户名：%s\n管理密码：%s\n管理地址：http://%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" "$LISTEN"
  if [[ "$LISTEN" == 127.0.0.1:* ]]; then
    printf '通过 SSH 隧道访问：ssh -N -L %s:127.0.0.1:%s 用户@服务器\n浏览器打开：http://127.0.0.1:%s\n' "$PORT" "$PORT" "$PORT"
  else echo '远程访问管理后台时，请配置 HTTPS 或限制管理端口来源。'; fi
else echo '原密码、监听地址与转发规则已保留。'; fi
echo 'HAProxy 仅转发 TCP。请放行云安全组及本机防火墙 INPUT 中的监听端口。'
