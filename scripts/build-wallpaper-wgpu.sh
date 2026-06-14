#!/bin/bash
# build-wallpaper-wgpu.sh — 部署 wallpaper-wgpu 渲染器 + DXC + 内嵌 assets
#
# 功能:
#   1. 将预编译的 wallpaper-wgpu 复制到 Resources/
#   2. 将 DXC (dxc + libdxcompiler.dylib) 复制到 Resources/
#   3. 将 Resources/assets/ 打包为 zip，通过汇编 .incbin 嵌入到 Resources/zip_data.o
#      供 WallpaperEngineEmbeddedAssets 在运行时解压
#   4. 签名所有二进制文件
#
# 用法: ./scripts/build-wallpaper-wgpu.sh
# 环境变量:
#   WAIFUX_WGPU_SRC       — wallpaper-wgpu 来源路径（默认 ~/Downloads/wallpaper-wgpu）
#   WAIFUX_DXC_SRC        — dxc 来源路径（默认 ~/Desktop/dxc）
#   WAIFUX_DXC_DYLIB_SRC  — libdxcompiler.dylib 来源路径（默认 ~/Desktop/libdxcompiler.dylib）
#   WAIFUX_FORCE_EMBED_ASSETS — 设为 1 时强制重新生成内嵌 assets

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST_DIR="$ROOT/Resources"
DEST_LIB_DIR="$DEST_DIR/lib"
RENDERER_ENTITLEMENTS="$ROOT/WallpaperRenderer.entitlements"
mkdir -p "$DEST_DIR" "$DEST_LIB_DIR"

echo "🔧 wallpaper-wgpu 部署开始..."

# ── 1. 复制 wallpaper-wgpu ──────────────────────────────────────
WGUI_SRC="${WAIFUX_WGPU_SRC:-}"
if [[ -z "$WGUI_SRC" ]]; then
  # 尝试多个可能的路径
  for candidate in \
    "$ROOT/wallpaper-wgpu" \
    "$ROOT/Resources/wallpaper-wgpu" \
    "$HOME/Downloads/wallpaper-wgpu" \
    "/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu/target/release/wallpaper-wgpu"; do
    if [[ -f "$candidate" ]]; then
      WGUI_SRC="$candidate"
      break
    fi
  done
fi
# 如果 Resources/wallpaper-wgpu 已存在且未指定源，跳过复制
if [[ -f "$DEST_DIR/wallpaper-wgpu" && -z "${WAIFUX_WGPU_SRC:-}" ]]; then
  echo "  ✅ wallpaper-wgpu 已存在，跳过复制"
elif [[ -n "$WGUI_SRC" && -f "$WGUI_SRC" ]]; then
  cp "$WGUI_SRC" "$DEST_DIR/wallpaper-wgpu"
  chmod +x "$DEST_DIR/wallpaper-wgpu"
  echo "  ✅ wallpaper-wgpu → $DEST_DIR/wallpaper-wgpu"
else
  echo "  ⚠️  wallpaper-wgpu 未找到，跳过复制"
fi

# ── 1.5 复制 ffmpeg（bake 命令需要） ────────────────────────────
FFMPEG_SRC="${WAIFUX_FFMPEG_SRC:-/opt/homebrew/bin/ffmpeg}"
# 如果是符号链接，解析真实路径（macOS readlink 不支持 -f）
if [[ -L "$FFMPEG_SRC" ]]; then
  FFMPEG_SRC="$(cd "$(dirname "$FFMPEG_SRC")" && pwd)/$(basename "$FFMPEG_SRC")"
  # 如果还是链接，用 stat 获取真实路径
  if [[ -L "$FFMPEG_SRC" ]]; then
    FFMPEG_SRC="$(stat -f%R "$FFMPEG_SRC" 2>/dev/null || echo "$FFMPEG_SRC")"
  fi
fi
if [[ -f "$FFMPEG_SRC" ]]; then
  cp "$FFMPEG_SRC" "$DEST_DIR/ffmpeg"
  chmod +x "$DEST_DIR/ffmpeg"
  echo "  ✅ ffmpeg → $DEST_DIR/ffmpeg"
else
  echo "  ⚠️  ffmpeg 未找到（$FFMPEG_SRC），bake 功能将不可用"
fi

# ── 2. 复制 DXC ─────────────────────────────────────────────────
DXC_SRC="${WAIFUX_DXC_SRC:-}"
DXC_DYLIB_SRC="${WAIFUX_DXC_DYLIB_SRC:-}"

# 如果未指定源路径，尝试多个位置
if [[ -z "$DXC_SRC" ]]; then
  for candidate in \
    "$HOME/Desktop/dxc" \
    "$ROOT/Resources/dxc" \
    "/opt/homebrew/bin/dxc"; do
    if [[ -f "$candidate" ]]; then
      DXC_SRC="$candidate"
      break
    fi
  done
fi

if [[ -z "$DXC_DYLIB_SRC" ]]; then
  for candidate in \
    "$HOME/Desktop/libdxcompiler.dylib" \
    "$ROOT/Resources/lib/libdxcompiler.dylib" \
    "/opt/homebrew/lib/libdxcompiler.dylib"; do
    if [[ -f "$candidate" ]]; then
      DXC_DYLIB_SRC="$candidate"
      break
    fi
  done
fi

# 如果 Resources 下已存在且未指定源，跳过复制
if [[ -f "$DEST_DIR/dxc" && -z "${WAIFUX_DXC_SRC:-}" ]]; then
  echo "  ✅ dxc 已存在，跳过复制"
elif [[ -n "$DXC_SRC" && -f "$DXC_SRC" ]]; then
  cp "$DXC_SRC" "$DEST_DIR/dxc"
  chmod +x "$DEST_DIR/dxc"
  # dxc 已有 @executable_path/../lib rpath，但由于 Xcode 的 folder reference
  # 会将 Resources/ 嵌套复制到 .app/Contents/Resources/Resources/ 下，
  # dxc 的 @loader_path/../lib 会指向错误的目录。
  # 添加 @loader_path/lib 以兼容嵌套结构（dxc 与 lib/ 同级）。
  install_name_tool -add_rpath "@loader_path/lib" "$DEST_DIR/dxc" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../lib" "$DEST_DIR/dxc" 2>/dev/null || true
  # 重新签名（install_name_tool 会失效签名）
  codesign --force --sign - "$DEST_DIR/dxc" 2>/dev/null || true
  echo "  ✅ dxc → $DEST_DIR/dxc"
else
  echo "  ⚠️  dxc 未找到，跳过复制"
fi

if [[ -f "$DEST_LIB_DIR/libdxcompiler.dylib" && -z "${WAIFUX_DXC_DYLIB_SRC:-}" ]]; then
  echo "  ✅ libdxcompiler.dylib 已存在，跳过复制"
elif [[ -n "$DXC_DYLIB_SRC" && -f "$DXC_DYLIB_SRC" ]]; then
  cp "$DXC_DYLIB_SRC" "$DEST_LIB_DIR/libdxcompiler.dylib"
  chmod +x "$DEST_LIB_DIR/libdxcompiler.dylib"
  echo "  ✅ libdxcompiler.dylib → $DEST_LIB_DIR/libdxcompiler.dylib"
else
  echo "  ⚠️  libdxcompiler.dylib 未找到，跳过复制"
fi

# ── 3. 生成内嵌 assets (.incbin) ─────────────────────────────────
ASSETS_DIR="$ROOT/Resources/assets"
ZIP_DATA_S="$DEST_DIR/zip_data.s"
ZIP_DATA_O="$DEST_DIR/zip_data.o"
ZIP_ACCESSOR_C="$DEST_DIR/zip_accessor.c"
ZIP_ACCESSOR_O="$DEST_DIR/zip_accessor.o"
TMP_ZIP="/tmp/waifux-embedded-assets-$$.zip"
rm -f "$TMP_ZIP"
cleanup() { rm -f "$TMP_ZIP"; }
trap cleanup EXIT

REQUIRED_EMBED_ARCHS=(arm64 x86_64)

object_has_arch() {
  local object_file="$1"
  local arch="$2"
  [[ -f "$object_file" ]] && lipo -info "$object_file" 2>/dev/null | grep -qE "(are:|architecture:) .*\\b${arch}\\b"
}

embedded_objects_are_current() {
  local object_file
  for object_file in "$ZIP_DATA_O" "$ZIP_ACCESSOR_O"; do
    [[ -f "$object_file" ]] || return 1
    local arch
    for arch in "${REQUIRED_EMBED_ARCHS[@]}"; do
      object_has_arch "$object_file" "$arch" || return 1
    done
  done
}

HAS_ASSETS=false
if [[ -d "$ASSETS_DIR" ]] && [[ -n "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]]; then
  HAS_ASSETS=true
fi

FORCE="${WAIFUX_FORCE_EMBED_ASSETS:-}"
# 如果 .o 已存在且 assets 未变化，跳过重新生成（除非 FORCE=1）
if embedded_objects_are_current && [[ -z "$FORCE" ]]; then
  echo "  🔄 内嵌 assets .o 已存在，跳过（设 WAIFUX_FORCE_EMBED_ASSETS=1 强制重编）"
else
  echo "  📦 生成内嵌 assets..."
  if [[ "$HAS_ASSETS" == true ]]; then
    ( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )
    echo "  ✅ assets 打包完成 ($(stat -f%z "$TMP_ZIP") bytes)"
  else
    echo -n > "$TMP_ZIP"
    echo "  ℹ️  无 assets，生成空占位"
  fi

  # 生成汇编 .incbin
  cat > "$ZIP_DATA_S" << EOF
	.globl _zip_data_start
	.globl _zip_data_end
_zip_data_start:
	.incbin "$TMP_ZIP"
_zip_data_end:
EOF

  # 生成 C bridge
  cat > "$ZIP_ACCESSOR_C" << 'EOF'
#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
EOF

  data_objects=()
  accessor_objects=()
  for arch in "${REQUIRED_EMBED_ARCHS[@]}"; do
    data_object="$DEST_DIR/zip_data.${arch}.o"
    accessor_object="$DEST_DIR/zip_accessor.${arch}.o"
    as -arch "$arch" -mmacosx-version-min=14.0 "$ZIP_DATA_S" -o "$data_object"
    clang -arch "$arch" -c -mmacosx-version-min=14.0 "$ZIP_ACCESSOR_C" -o "$accessor_object"
    data_objects+=("$data_object")
    accessor_objects+=("$accessor_object")
  done

  lipo -create "${data_objects[@]}" -output "$ZIP_DATA_O"
  lipo -create "${accessor_objects[@]}" -output "$ZIP_ACCESSOR_O"
  rm -f "${data_objects[@]}" "${accessor_objects[@]}"
  echo "  ✅ zip_data.o / zip_accessor.o 生成（universal）"
fi

# ── 4. 签名 ──────────────────────────────────────────────────────
if command -v codesign >/dev/null 2>&1; then
  echo "  🔏 签名..."
  if [[ -f "$DEST_DIR/wallpaper-wgpu" ]]; then
    if [[ -f "$RENDERER_ENTITLEMENTS" ]]; then
      codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || \
        codesign --force -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || true
    else
      codesign --force -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || true
    fi
  fi
  if [[ -f "$DEST_DIR/dxc" ]]; then
    codesign --force -s - "$DEST_DIR/dxc" 2>/dev/null || true
  fi
  if [[ -f "$DEST_LIB_DIR/libdxcompiler.dylib" ]]; then
    codesign --force -s - "$DEST_LIB_DIR/libdxcompiler.dylib" 2>/dev/null || true
  fi
  if [[ -f "$DEST_DIR/ffmpeg" ]]; then
    codesign --force -s - "$DEST_DIR/ffmpeg" 2>/dev/null || true
  fi
  echo "  ✅ 签名完成"
fi

# ── 5. 同步到根目录（开发调试用） ──────────────────────────────
if [[ -f "$DEST_DIR/wallpaper-wgpu" ]]; then
  cp "$DEST_DIR/wallpaper-wgpu" "$ROOT/wallpaper-wgpu"
fi

echo "✅ build-wallpaper-wgpu 完成"
