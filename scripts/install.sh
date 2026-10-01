#!/usr/bin/env bash
# Download and install a prebuilt Node.js/TypeScript + Vue release. No Docker.
set -euo pipefail

REPO=${FASTPROXY_REPO:-bunnya33/fastproxy}
RELEASE_VERSION=latest
PACKAGE=''
LISTEN=${FASTPROXY_LISTEN:-127.0.0.1:8080}
ADMIN_USER=${FASTPROXY_ADMIN_USER:-admin}
ADMIN_PASSWORD=${FASTPROXY_ADMIN_PASSWORD:-}
NODE_VERSION=${FASTPROXY_NODE_VERSION:-}
INSTALL_ROOT=/opt/fastproxy
CHECK_ONLY=false

usage() {
  cat <<'HELP'
FastProxy 安装 / 更新（Debian 12+、Ubuntu 20.04+，systemd）
  bash install.sh --repo OWNER/REPO [--version v0.1.2]
  bash install.sh --package /path/fastproxy-v0.1.2.tar.gz
选项：
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
    --repo|--version|--package|--listen|--user)
      [[ $# -ge 2 ]] || die "$1 缺少参数"
      case "$1" in --repo) REPO=$2 ;; --version) RELEASE_VERSION=$2 ;; --package) PACKAGE=$2 ;; --listen) LISTEN=$2 ;; --user) ADMIN_USER=$2 ;; esac
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
if [[ -z "$PACKAGE" ]]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '请指定 --repo OWNER/REPO，或 --package 本地发布包'
  [[ "$RELEASE_VERSION" == latest || "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '版本格式应为 v0.1.2 或 latest'
else
  [[ -f "$PACKAGE" ]] || die '本地发布包不存在'
  PACKAGE=$(realpath "$PACKAGE")
fi
if [[ "$CHECK_ONLY" == true ]]; then
  echo "环境检查通过：${PRETTY_NAME:-Linux}，$ARCH，systemd；安装位置 $INSTALL_ROOT"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl jq nftables iproute2 xz-utils openssl libstdc++6
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ -z "$PACKAGE" ]]; then
  if [[ "$RELEASE_VERSION" == latest ]]; then
    RELEASE_VERSION=$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name')
    [[ "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '未找到正式发布版本，请先创建 GitHub Release'
  fi
  FILE="fastproxy-$RELEASE_VERSION.tar.gz"
  BASE="https://github.com/$REPO/releases/download/$RELEASE_VERSION"
  curl -fsSL --proto '=https' --tlsv1.2 "$BASE/$FILE" -o "$TMP/$FILE"
  curl -fsSL --proto '=https' --tlsv1.2 "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"
  (cd "$TMP" && awk -v file="$FILE" '$2 == file || $2 == "*" file {print}' SHA256SUMS > selected.sha256 && [[ -s selected.sha256 ]] && sha256sum -c selected.sha256) || die '发布包校验失败'
  PACKAGE="$TMP/$FILE"
fi
# Reject traversal and symlinks before extracting as root.
tar -tzf "$PACKAGE" | awk '/(^\/|(^|\/)\.\.($|\/))/ {bad=1} END {exit bad}' || die '发布包包含非法路径'
tar -tvzf "$PACKAGE" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {bad=1} END {exit bad}' || die '发布包包含链接或特殊文件'
mkdir -p "$TMP/app"
tar --no-same-owner -xzf "$PACKAGE" -C "$TMP/app"
[[ -f "$TMP/app/apps/server/dist/main.js" && -f "$TMP/app/apps/server/public/index.html" && -f "$TMP/app/start" && -f "$TMP/app/scripts/fastproxy.service" && -d "$TMP/app/node_modules/fastify" ]] || die '发布包不完整'

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
FASTPROXY_MODE=nftables
FASTPROXY_LISTEN=$LISTEN
FASTPROXY_ADMIN_USER=$ADMIN_USER
FASTPROXY_ADMIN_PASSWORD="$ESCAPED"
FASTPROXY_COOKIE_SECURE=false
FASTPROXY_PROTECTED_PORTS=$SSH_PORT
FASTPROXY_DATA_DIR=/var/lib/fastproxy
FASTPROXY_SOCKET=/run/fastproxy/control.sock
FASTPROXY_NFT_BINARY=/usr/sbin/nft
ENV
  chmod 600 /etc/fastproxy/fastproxy.env
fi
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-fastproxy.conf
sysctl -p /etc/sysctl.d/90-fastproxy.conf >/dev/null

# Stop the old service only after the new package and runtime are ready.
[[ ! -e "$INSTALL_ROOT.previous" ]] || die "已有 $INSTALL_ROOT.previous，请先处理上次更新的备份"
[[ ! -e "$INSTALL_ROOT.failed" ]] || die "已有 $INSTALL_ROOT.failed，请先处理上次失败的版本"
WAS_ACTIVE=false
if systemctl is-active --quiet fastproxy; then WAS_ACTIVE=true; systemctl stop fastproxy; fi
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
echo
echo 'FastProxy 已安装，数字菜单：sudo fastproxy'
if [[ "$FIRST_INSTALL" == true ]]; then
  printf '管理用户名：%s\n管理密码：%s\n管理地址：http://%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" "$LISTEN"
  if [[ "$LISTEN" == 127.0.0.1:* ]]; then
    printf '通过 SSH 隧道访问：ssh -N -L %s:127.0.0.1:%s 用户@服务器\n浏览器打开：http://127.0.0.1:%s\n' "$PORT" "$PORT" "$PORT"
  else echo '远程访问管理后台时，请配置 HTTPS 或限制管理端口来源。'; fi
else echo '原密码、监听地址与转发规则已保留。'; fi
echo '如使用 UFW / firewalld，还需放行 FORWARD 流量和云安全组中的转发端口。'
