#!/bin/bash
#
# Fetches the licence texts that ship inside the app straight from their
# official sources, verifies each against a pinned SHA-256, and installs them
# into licenses/.
#
#   scripts/fetch-licenses.sh
#
# Why a script instead of just committing the files: "it is in the repo" is not
# provenance. Every file below is downloaded from the publisher — FSF for the
# LGPL, the official 7-zip.org source release for the two 7-Zip licence files —
# checked against a hash recorded here, and only then copied into place. If a
# publisher ever republishes different bytes, this fails loudly instead of
# quietly shipping whatever happens to be on disk.
#
# Verify by hand, without this script:
#
#   curl -sSL https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt | shasum -a 256
#   # 期望 20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95
#
#   curl -sSL https://www.7-zip.org/a/7z2603-src.tar.xz | shasum -a 256
#   # 期望 9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4
#   tar -xJOf 7z2603-src.tar.xz DOC/License.txt | shasum -a 256
#   # 期望 9ac2b4a97ab5d523965534d8b2d5868e511b39096d51fff458ab72c38b80fccc
#   tar -xJOf 7z2603-src.tar.xz DOC/unRarLicense.txt | shasum -a 256
#   # 期望 17bd9fa4399092c777536fff045b41df76ec9d2ac4c9b8e7345d3b8b6ccc7976

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$ROOT/build/license-download"
LICENSE_DIR="$ROOT/licenses"

SOURCE_VERSION="26.03"
COMPACT="${SOURCE_VERSION/./}"
SOURCE_ARCHIVE="$ROOT/source/7z${COMPACT}-src.tar.xz"
SOURCE_URL="https://www.7-zip.org/a/7z${COMPACT}-src.tar.xz"
SOURCE_SHA256="9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4"

LGPL_URL="https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt"
LGPL_SHA256="20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95"
ZIP_LICENSE_SHA256="9ac2b4a97ab5d523965534d8b2d5868e511b39096d51fff458ab72c38b80fccc"
UNRAR_LICENSE_SHA256="17bd9fa4399092c777536fff045b41df76ec9d2ac4c9b8e7345d3b8b6ccc7976"

verify() {
  local file="$1" expected="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "  ✗ $label：文件不存在（$file）" >&2
    exit 1
  fi
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "  ✗ $label：哈希不匹配" >&2
    echo "      期望 $expected" >&2
    echo "      实际 $actual" >&2
    echo "    上游可能已更新文件；请人工核对后再更新本脚本里的哈希。" >&2
    exit 1
  fi
  echo "  ✓ $label  $actual"
}

mkdir -p "$WORK"
rm -f "$WORK/LGPL-2.1.txt"
rm -rf "$WORK/DOC"

echo "==> 从 FSF 官方下载 GNU LGPL 2.1 全文"
echo "    $LGPL_URL"
curl -L --retry 5 --retry-delay 3 --fail -o "$WORK/LGPL-2.1.txt" "$LGPL_URL"
verify "$WORK/LGPL-2.1.txt" "$LGPL_SHA256" "LGPL-2.1.txt"

echo "==> 取 7-Zip 官方源码包内的许可文件"
if [[ -f "$SOURCE_ARCHIVE" ]]; then
  echo "    使用已下载的源码包：$SOURCE_ARCHIVE"
else
  echo "    本地没有源码包，从官网下载…"
  mkdir -p "$(dirname "$SOURCE_ARCHIVE")"
  curl -L --retry 5 --retry-delay 3 --fail -o "$SOURCE_ARCHIVE" "$SOURCE_URL"
fi
echo "    $SOURCE_URL"
verify "$SOURCE_ARCHIVE" "$SOURCE_SHA256" "7z${COMPACT}-src.tar.xz"
xz -t "$SOURCE_ARCHIVE"

tar -xJf "$SOURCE_ARCHIVE" -C "$WORK" DOC/License.txt DOC/unRarLicense.txt
verify "$WORK/DOC/License.txt" "$ZIP_LICENSE_SHA256" "7-Zip-License.txt"
verify "$WORK/DOC/unRarLicense.txt" "$UNRAR_LICENSE_SHA256" "unRarLicense.txt"

echo "==> 安装到 licenses/"
install -m 644 "$WORK/LGPL-2.1.txt" "$LICENSE_DIR/LGPL-2.1.txt"
install -m 644 "$WORK/DOC/License.txt" "$LICENSE_DIR/7-Zip-License.txt"
install -m 644 "$WORK/DOC/unRarLicense.txt" "$LICENSE_DIR/unRarLicense.txt"
( cd "$LICENSE_DIR" && shasum -a 256 7-Zip-License.txt LGPL-2.1.txt unRarLicense.txt > SHA256SUMS )

cat "$LICENSE_DIR/SHA256SUMS"
echo
echo "==> 完成。scripts/build-app.sh 在复制前会用 licenses/SHA256SUMS 再校验一次。"
