#!/bin/bash
#
# Downloads and extracts the official 7-Zip source release.
#
#   scripts/fetch-source.sh [version]
#
# Default version: 26.03. The tarball comes from the official 7-zip.org host,
# which is the download link published on https://www.7-zip.org/download.html.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-26.03}"
COMPACT="${VERSION/./}"

ARCHIVE="$ROOT/source/7z${COMPACT}-src.tar.xz"
DEST="$ROOT/source/src"
URL="https://www.7-zip.org/a/7z${COMPACT}-src.tar.xz"

mkdir -p "$ROOT/source"

echo "==> 下载 7-Zip $VERSION 源码"
echo "    $URL"
if [[ -f "$ARCHIVE" ]]; then
  echo "    已存在，断点续传…"
  curl -L -C - --retry 5 --retry-delay 3 -o "$ARCHIVE" "$URL"
else
  curl -L --retry 5 --retry-delay 3 -o "$ARCHIVE" "$URL"
fi

echo "==> 校验压缩包完整性"
xz -t "$ARCHIVE"
shasum -a 256 "$ARCHIVE"

echo "==> 解压到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST"

echo "==> 源码就绪"
ls "$DEST"
echo
echo "下一步：scripts/build-app.sh"
