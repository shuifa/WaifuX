#!/bin/bash
# 将 Resources/assets 打成 zip，编译进 wallpaperengine-cli（通过汇编 .incbin 嵌入 Mach-O）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASSETS_DIR="$ROOT/Resources/assets"
SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
SRC_EMBED="$ROOT/WallpaperEngineEmbeddedAssets.swift"
OUT_CLI="$ROOT/Resources/wallpaperengine-cli"
TMP_ZIP="/tmp/waifux-we-assets-$$.zip"
rm -f "$TMP_ZIP"

cleanup() { rm -f "$TMP_ZIP"; }
# 注意：Resources/{zip_data.s,zip_data.o,zip_accessor.c,zip_accessor.o} 是仓库 committed
# 文件，App 主程序也会通过 OTHER_LDFLAGS 链接 zip_data.o + zip_accessor.o（见
# WaifuX.xcodeproj/project.pbxproj 与 WallpaperEngineEmbeddedAssets.swift）。
# 早期版本会在脚本结束时一并删除它们，但这样会让随后的 xcodebuild 因缺 .o 链接失败。
# 这里只清理临时 zip，保留生成的 .s/.c/.o 留作 App 构建输入。
trap cleanup EXIT

if [[ ! -f "$SRC_MAIN" || ! -f "$SRC_EMBED" ]]; then
  echo "error: missing Swift sources" >&2
  exit 1
fi

HAS_ASSETS=false
if [[ -d "$ASSETS_DIR" ]] && [[ -n "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]]; then
  HAS_ASSETS=true
fi

if [[ "$HAS_ASSETS" == true ]]; then
  echo "[build-wallpaperengine-cli] Zipping assets..."
  ( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )
else
  echo "[build-wallpaperengine-cli] 无 assets，构建空资源占位"
  echo -n "" > "$TMP_ZIP"
fi

echo "[build-wallpaperengine-cli] 生成汇编文件嵌入 zip..."
cat > "$ROOT/Resources/zip_data.s" << EOF
	.globl _zip_data_start
	.globl _zip_data_end
_zip_data_start:
	.incbin "$TMP_ZIP"
_zip_data_end:
EOF

as -arch arm64 -mmacosx-version-min=14.0 "$ROOT/Resources/zip_data.s" -o "$ROOT/Resources/zip_data.o"

echo "[build-wallpaperengine-cli] 生成 C bridge..."
cat > "$ROOT/Resources/zip_accessor.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
EOF

clang -c -mmacosx-version-min=14.0 "$ROOT/Resources/zip_accessor.c" -o "$ROOT/Resources/zip_accessor.o"

echo "[build-wallpaperengine-cli] swiftc..."
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -I Resources/CRenderer -I Resources -L Resources/lib \
  -llinux-wallpaperengine-renderer \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -Xlinker -rpath -Xlinker @loader_path/Resources/lib \
  -Xlinker -rpath -Xlinker @loader_path/../Resources/lib \
  -Xlinker -rpath -Xlinker @loader_path/lib \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN" "$SRC_EMBED" \
  "$ROOT/Resources/zip_data.o" "$ROOT/Resources/zip_accessor.o"

# The renderer dylib may carry an @loader_path install name from local builds,
# but our CLI is shipped both at repo root and under Resources/.
install_name_tool -change "@loader_path/liblinux-wallpaperengine-renderer.dylib" "@rpath/liblinux-wallpaperengine-renderer.dylib" "$OUT_CLI" 2>/dev/null || true

if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  codesign --force -s - "$OUT_CLI" 2>/dev/null || true
fi

cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"

# Bundle Homebrew dylibs 到 Resources/，避免用户机器上没有 Homebrew 时 dyld 报错
echo "[build-wallpaperengine-cli] Bundling Homebrew dylibs..."
if [[ -f "$ROOT/scripts/bundle-dylibs.py" ]]; then
  python3 "$ROOT/scripts/bundle-dylibs.py" "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" "$ROOT/Resources/lib"
  # 重新签名所有被修改过的 dylib
  for f in "$ROOT"/Resources/lib/*.dylib; do
    codesign --force -s - "$f" 2>/dev/null || true
  done
  # 确保 renderer dylib 的 id 是 @rpath/...，让 CLI 能跨位置解析
  install_name_tool -id "@rpath/liblinux-wallpaperengine-renderer.dylib" "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true
  codesign --force -s - "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true

  # 复制 Homebrew Python（libvapoursynth-script 需要），若不存在则尝试从 Homebrew 复制
  if [[ ! -f "$ROOT/Resources/lib/Python" ]]; then
    PYTHON_CANDIDATE="/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python"
    if [[ -f "$PYTHON_CANDIDATE" ]]; then
      cp "$PYTHON_CANDIDATE" "$ROOT/Resources/lib/Python"
      chmod +x "$ROOT/Resources/lib/Python"
      install_name_tool -id "@loader_path/Python" "$ROOT/Resources/lib/Python" 2>/dev/null || true
      codesign --force -s - "$ROOT/Resources/lib/Python" 2>/dev/null || true
      echo "[build-wallpaperengine-cli] Copied Python framework"
    fi
  fi

  # 🔧 安全网：修复 bundle-dylibs.py 可能遗漏的 @@HOMEBREW_ 占位符
  # 某些 Homebrew 构建的 dylib 中 CMake 变量（@@HOMEBREW_CELLAR@@ / @@HOMEBREW_PREFIX@@）
  # 可能未被正确替换，导致 dyld 找不到依赖。这里将它们全部转成 @loader_path/ 相对路径。
  echo "[build-wallpaperengine-cli] Fixing any remaining Homebrew placeholders..."
  FIXED_COUNT=0
  for f in "$ROOT"/Resources/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    while IFS= read -r line; do
      dep_path=$(echo "$line" | awk '{print $1}')
      if [[ "$dep_path" == *"@@HOMEBREW_CELLAR@@"* ]] || [[ "$dep_path" == *"@@HOMEBREW_PREFIX@@"* ]]; then
        dep_base=$(basename "$dep_path")
        new_dep="@loader_path/$dep_base"
        echo "    Fix: $(basename "$f") — $dep_path -> $new_dep"
        install_name_tool -change "$dep_path" "$new_dep" "$f" 2>/dev/null || true
        FIXED_COUNT=$((FIXED_COUNT + 1))
      fi
    done < <(otool -L "$f" 2>/dev/null | tail -n +2)
  done

  if [[ "$FIXED_COUNT" -gt 0 ]]; then
    echo "[build-wallpaperengine-cli] Fixed $FIXED_COUNT placeholder reference(s), re-signing..."
    # 重新签名所有受影响的 dylib
    for f in "$ROOT"/Resources/lib/*.dylib; do
      [[ -L "$f" ]] && continue
      codesign --force -s - "$f" 2>/dev/null || true
    done
    # 重新签名 CLI 二进制（根目录 + Resources 内两份）
    codesign --force -s - "$OUT_CLI" 2>/dev/null || true
    cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"
    codesign --force -s - "$ROOT/wallpaperengine-cli" 2>/dev/null || true
  fi
fi

echo "[build-wallpaperengine-cli] OK → $OUT_CLI"
