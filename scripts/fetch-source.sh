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
COMPACT="$(printf '%s' "$VERSION" | tr -d '.')"

# SHA-256 of the official source tarball, per version. These values were
# verified against a second official channel:
# https://github.com/ip7z/7zip/releases/download/<version>/7z<compact>-src.tar.xz
# See docs/verification.md. Add the new hash here before bumping the version.
case "$VERSION" in
  26.03) EXPECTED="9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4" ;;
  *)
    echo "错误：没有 7-Zip $VERSION 的已知哈希，拒绝在无法校验的情况下继续。" >&2
    echo "请先核对官方下载页，把该版本的 SHA-256 加入 scripts/fetch-source.sh 的 case 表。" >&2
    exit 1
    ;;
esac

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

echo "==> 校验 SHA-256"
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "    期望：$EXPECTED" >&2
  echo "    实际：$ACTUAL" >&2
  echo "错误：哈希不匹配，文件可能损坏或被篡改，已中止。" >&2
  exit 1
fi
echo "    匹配：$ACTUAL"

echo "==> 解压到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST"

echo "==> 源码就绪"
ls "$DEST"
echo
echo "下一步：scripts/build-app.sh"
