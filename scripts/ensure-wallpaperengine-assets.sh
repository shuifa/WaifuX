#!/bin/bash
# Resources/assets 不提交到 Git。本地可保留该目录；CI 可通过 WAIFUX_WE_ASSETS_PACK_URL 下载 zip（顶层须含 assets/）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/assets"

if [[ -d "$DEST" ]] && [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "[ensure-assets] 使用已有 $DEST"
  exit 0
fi

# 若 Assets 不可用，build-wallpaperengine-cli.sh 会自动创建空占位，因此此处仅警告不退出。
URL="${WAIFUX_WE_ASSETS_PACK_URL:-}"
if [[ -z "$URL" ]]; then
  echo "[ensure-assets] ⚠️ 本地无 $DEST 且未设置 WAIFUX_WE_ASSETS_PACK_URL，将使用空资源占位" >&2
  exit 0
fi

echo "[ensure-assets] 下载材质包..."
mkdir -p "$ROOT/Resources"
TMP="/tmp/waifux-wh-assets-pack-$$.zip"
curl -fL "$URL" -o "$TMP"
unzip -q -o "$TMP" -d "$ROOT/Resources"
rm -f "$TMP"

if [[ ! -d "$DEST" ]] || [[ -z "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "error: 解压后仍未得到 $DEST" >&2
  exit 1
fi
echo "[ensure-assets] OK → $DEST"
