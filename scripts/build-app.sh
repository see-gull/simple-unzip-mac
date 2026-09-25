#!/bin/bash
#
# Builds Simple Unzip.app from source.
#
#   1. compiles the 7-Zip 26.03 command line tool (7zz) if it is not built yet
#   2. compiles the Swift package in release configuration
#   3. assembles a self-contained .app bundle: binary, bundled 7zz, icon, plist
#   4. ad-hoc signs the result
#
# Usage: scripts/build-app.sh [--skip-engine]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The product name deliberately does NOT contain "7-Zip" or "RAR": those are
# third-party trademarks, and using them as our own product name would wrongly
# imply an official connection. They are only referenced when stating which
# engine this app uses.
APP_NAME="Simple Unzip"
# Change this to your own reverse-DNS identifier before publishing.
BUNDLE_ID="app.simpleunzip.mac"
VERSION="1.0.0"

SOURCE_DIR="$ROOT/source/src"
ENGINE_BIN="$ROOT/build/bin/7zz"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

SKIP_ENGINE=0
for argument in "$@"; do
  case "$argument" in
    --skip-engine) SKIP_ENGINE=1 ;;
    *) echo "未知参数：$argument" >&2; exit 2 ;;
  esac
done

# SwiftPM needs writable caches; keep them inside the workspace.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/modulecache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_DIR/modulecache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

SWIFT_FLAGS=(--disable-sandbox --scratch-path "$BUILD_DIR/app-build" --cache-path "$BUILD_DIR/spm-cache")

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# --------------------------------------------------------------------------
step "1/5 检查 7-Zip 引擎"
if [[ "$SKIP_ENGINE" -eq 0 ]]; then
  if [[ ! -x "$ENGINE_BIN" ]]; then
    if [[ ! -d "$SOURCE_DIR" ]]; then
      echo "找不到 7-Zip 源码目录：$SOURCE_DIR" >&2
      echo "请先运行 scripts/fetch-source.sh 下载并解压官方源码。" >&2
      exit 1
    fi
    echo "从源码编译 7zz…"
    mkdir -p "$(dirname "$ENGINE_BIN")"
    make -C "$SOURCE_DIR/CPP/7zip/Bundles/Alone2" -j"$(sysctl -n hw.ncpu)" \
      -f ../../cmpl_mac_arm64.mak >/dev/null
    cp "$SOURCE_DIR/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz" "$ENGINE_BIN"
  fi
fi

if [[ ! -x "$ENGINE_BIN" ]]; then
  echo "7zz 不可用：$ENGINE_BIN" >&2
  exit 1
fi
echo "引擎：$ENGINE_BIN"
"$ENGINE_BIN" | sed -n '2p'

# --------------------------------------------------------------------------
step "2/5 编译 Swift 包（release）"
cd "$ROOT/app"
swift build -c release --product SimpleUnzip "${SWIFT_FLAGS[@]}"
BINARY="$BUILD_DIR/app-build/release/SimpleUnzip"
[[ -x "$BINARY" ]] || { echo "未找到可执行文件：$BINARY" >&2; exit 1; }

# --------------------------------------------------------------------------
step "3/5 生成图标"
ICON_WORK="$BUILD_DIR/icon"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICON_WORK/icon-1024.png"

for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $pair
  sips -z "$1" "$1" "$ICON_WORK/icon-1024.png" \
    --out "$ICON_WORK/AppIcon.iconset/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICON_WORK/AppIcon.icns"

# --------------------------------------------------------------------------
step "4/5 组装 .app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/SimpleUnzip"
cp "$ENGINE_BIN" "$APP_BUNDLE/Contents/Resources/7zz"
chmod +x "$APP_BUNDLE/Contents/MacOS/SimpleUnzip" "$APP_BUNDLE/Contents/Resources/7zz"
cp "$ICON_WORK/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Ship the licences that cover the bundled 7-Zip code. Prefer the copies
# committed under licenses/ so the app builds identically from a clean clone;
# fall back to the freshly downloaded source tree.
if [[ -f "$ROOT/licenses/7-Zip-License.txt" ]]; then
  cp "$ROOT/licenses/7-Zip-License.txt" "$APP_BUNDLE/Contents/Resources/7-Zip-License.txt"
elif [[ -f "$SOURCE_DIR/DOC/License.txt" ]]; then
  cp "$SOURCE_DIR/DOC/License.txt" "$APP_BUNDLE/Contents/Resources/7-Zip-License.txt"
fi
if [[ -f "$ROOT/licenses/unRarLicense.txt" ]]; then
  cp "$ROOT/licenses/unRarLicense.txt" "$APP_BUNDLE/Contents/Resources/unRarLicense.txt"
elif [[ -f "$SOURCE_DIR/DOC/unRarLicense.txt" ]]; then
  cp "$SOURCE_DIR/DOC/unRarLicense.txt" "$APP_BUNDLE/Contents/Resources/unRarLicense.txt"
fi
# Third-party notice. This file is what satisfies the source-availability
# obligation when the app is distributed on its own: 7-Zip ships as an
# unmodified separate executable, so naming the exact version, the official
# source location and its checksum is enough to comply.
rm -f "$APP_BUNDLE/Contents/Resources/ENGINE-VERSION.txt"
cat > "$APP_BUNDLE/Contents/Resources/NOTICE.txt" <<NOTICE
Simple Unzip — 第三方组件声明
=============================

本应用包含 7-Zip 的命令行程序（包内文件名为 7zz）。该程序按原样使用，
未经任何修改。

  引擎版本   $( "$ENGINE_BIN" | sed -n '2p' )
  版权归属   Copyright (c) 1999-2026 Igor Pavlov
  适用许可   GNU LGPL。其中部分文件为 BSD-2 / BSD-3 或 public domain，
             具体见同目录下的 7-Zip-License.txt
  源码地址   https://www.7-zip.org/a/7z2603-src.tar.xz
  SHA-256    9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4

  如需上述源码，请通过本应用的发布页面提出，作者将予以提供。

随本应用分发的许可文本：

  7-Zip-License.txt   7-Zip 各组件的许可说明
  unRarLicense.txt    unRAR 代码许可


关于 RAR 代码的强制声明
-----------------------

The unRAR sources may be used in any software to handle RAR archives without
limitations free of charge, but cannot be used to re-create the RAR compression
algorithm, which is proprietary. Distribution of modified unRAR sources in
separate form or as a part of other software is permitted, provided that it is
clearly stated in the documentation and source comments that the code may not
be used to develop a RAR (WinRAR) compatible archiver.

据此声明：本应用包含的 unRAR 相关代码，不得被用于开发任何 RAR（WinRAR）
兼容的压缩程序。本应用不提供 RAR 压缩功能，仅使用该代码读取与解压 RAR 归档。


无关联声明
----------

本应用为独立开发的第三方软件，与 Igor Pavlov（7-Zip 作者）以及
Alexander Roshal / RARLAB（RAR、WinRAR 作者）无任何关联，
未获得其授权、赞助或背书。


本应用免费提供，不收取任何费用。
NOTICE

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>SimpleUnzip</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>压缩包</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.archive</string>
                <string>public.zip-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>public.bzip2-archive</string>
                <string>public.xz-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>public.iso-image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# --------------------------------------------------------------------------
step "5/5 临时签名"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 \
  && echo "已使用 ad-hoc 签名" \
  || echo "ad-hoc 签名被跳过（不影响本机使用）"

codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1 \
  && echo "签名校验通过" \
  || echo "签名校验未通过（本机仍可运行）"

printf '\n\033[1;32m完成\033[0m  %s\n' "$APP_BUNDLE"
du -sh "$APP_BUNDLE"
