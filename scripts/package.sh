#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(node -p 'require("./package.json").version')
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
npm run build
mkdir -p "$STAGE/apps/server" "$STAGE/apps/web" "$STAGE/scripts" "$ROOT/dist"
cp package.json package-lock.json "$STAGE/"
cp apps/server/package.json "$STAGE/apps/server/"
cp apps/web/package.json "$STAGE/apps/web/"
cp -R apps/server/dist apps/server/public "$STAGE/apps/server/"
cp scripts/fastproxy scripts/fastproxy.service scripts/start scripts/install.sh "$STAGE/scripts/"
cp README.md LICENSE "$STAGE/"
(cd "$STAGE" && npm ci --omit=dev --workspace @fastproxy/server --include-workspace-root=false --ignore-scripts)
cp "$STAGE/scripts/start" "$STAGE/start"
chmod +x "$STAGE/start" "$STAGE/scripts/fastproxy" "$STAGE/scripts/install.sh"
tar --dereference -czf "$ROOT/dist/fastproxy-v$VERSION.tar.gz" -C "$STAGE" .
(cd "$ROOT/dist" && sha256sum "fastproxy-v$VERSION.tar.gz" > SHA256SUMS)
echo "发布包：dist/fastproxy-v$VERSION.tar.gz"
