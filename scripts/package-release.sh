#!/bin/bash
#
# Packages dist/Simple Unzip.app for a release, checks that the licence
# attachments are present in both the app bundle and the archive, and lays out
# two things:
#
#   release-for-github/upload-<版本>/   发布新版本要上传的全部附件
#                                       （应用 + 7zz + 许可证 + 源码）
#   release-for-github/LGPL-2.1.txt     一个文件，给已发布的旧版本补挂用
#
# The upload folder name is derived from the version inside the built app, so
# the folder and the artifact can never disagree.
#
# Usage: scripts/package-release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$ROOT/dist/Simple Unzip.app"
OUTPUT="$ROOT/dist/Simple Unzip.zip"
RELEASE_DIR="$ROOT/release-for-github"

SOURCE_ARCHIVE="$ROOT/source/7z2603-src.tar.xz"
SOURCE_SHA256="9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4"

REQUIRED=(
  "Contents/MacOS/SimpleUnzip"
  "Contents/Resources/7zz"
  "Contents/Resources/NOTICE.txt"
  "Contents/Resources/7-Zip-License.txt"
  "Contents/Resources/LGPL-2.1.txt"
  "Contents/Resources/unRarLicense.txt"
  "Contents/Resources/Simple-Unzip-LICENSE.txt"
)

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "找不到 $APP_BUNDLE，请先运行 scripts/build-app.sh。" >&2
  exit 1
fi

for required in "${REQUIRED[@]}"; do
  if [[ ! -s "$APP_BUNDLE/$required" ]]; then
    echo "应用包缺少 ${required#Contents/}，先补齐再打包。" >&2
    exit 1
  fi
done

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP_BUNDLE/Contents/Info.plist")"
UPLOAD_DIR="$RELEASE_DIR/upload-$VERSION"
BUNDLED_ENGINE="$APP_BUNDLE/Contents/Resources/7zz"

rm -f "$OUTPUT"
# `--sequesterRsrc` keeps resource forks in `__macOSX` rather than dropping
# them, matching what the hand-made zip used to contain.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$OUTPUT"

# The check that matters is on the file users actually download: a bundle can
# be complete while the archive that ships it is stale.
LISTING="$(unzip -l "$OUTPUT")"
for required in "${REQUIRED[@]}"; do
  case "$LISTING" in
    *"Simple Unzip.app/$required"*) ;;
    *)
      echo "压缩包内缺少 ${required#Contents/}：$OUTPUT" >&2
      exit 1
      ;;
  esac
done

echo "已生成 $OUTPUT（版本 $VERSION）"

# --------------------------------------------------------------------------
# 发布文件夹。release-for-github/ 按 .gitignore 不入库，这里只是把每次发布
# 要用的东西摆在一起，避免拿错或漏传。
# --------------------------------------------------------------------------
if [[ ! -d "$RELEASE_DIR" ]]; then
  echo "提示：没有 $RELEASE_DIR，跳过发布文件夹整理。"
  shasum -a 256 "$OUTPUT"
  exit 0
fi

mkdir -p "$UPLOAD_DIR"

# 每次重跑都清空重建，避免上一版的 zip / 源码包留在里面被误传。
find "$UPLOAD_DIR" -maxdepth 1 -type f ! -name '.DS_Store' -delete

cp "$OUTPUT" "$UPLOAD_DIR/Simple Unzip.zip"

# 7-Zip 引擎单独放一份，与应用包内的那份必须是同一个二进制。
cp "$BUNDLED_ENGINE" "$UPLOAD_DIR/7zz"
chmod 755 "$UPLOAD_DIR/7zz"
if [[ "$(shasum -a 256 "$BUNDLED_ENGINE" | awk '{print $1}')" \
   != "$(shasum -a 256 "$UPLOAD_DIR/7zz" | awk '{print $1}')" ]]; then
  echo "7zz 复制后校验失败，上传目录已污染，请重跑。" >&2
  exit 1
fi

cp "$ROOT/licenses/7-Zip-License.txt" "$UPLOAD_DIR/7-Zip-License.txt"
cp "$ROOT/licenses/LGPL-2.1.txt" "$UPLOAD_DIR/LGPL-2.1.txt"
cp "$ROOT/licenses/unRarLicense.txt" "$UPLOAD_DIR/unRarLicense.txt"
cp "$ROOT/LICENSE" "$UPLOAD_DIR/Simple-Unzip-LICENSE.txt"
chmod 644 "$UPLOAD_DIR"/*.txt

# 随包源码必须与 README 登记的官方哈希一致，否则宁可不放。
if [[ -f "$SOURCE_ARCHIVE" ]]; then
  actual="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
  if [[ "$actual" == "$SOURCE_SHA256" ]]; then
    cp "$SOURCE_ARCHIVE" "$UPLOAD_DIR/7z2603-src.tar.xz"
  else
    echo "警告：$SOURCE_ARCHIVE 哈希与官方登记值不一致，未放入上传目录。" >&2
    echo "      实际 $actual" >&2
  fi
else
  echo "警告：找不到 $SOURCE_ARCHIVE，上传目录暂缺源码包；" >&2
  echo "      请先运行 scripts/fetch-source.sh。" >&2
fi

# 旧版本补挂：只要这一个文件。LGPL 2.1 的条款文字不分应用版本，
# 已经发布过的版本挂同一份原文即可。
cp "$ROOT/licenses/LGPL-2.1.txt" "$RELEASE_DIR/LGPL-2.1.txt"
chmod 644 "$RELEASE_DIR/LGPL-2.1.txt"

# 发布页正文（更新说明）也放进上传目录：它不作为附件上传，只是让你发布时
# 不用跑到别的目录去找这份要粘贴的文案。
if [[ -f "$RELEASE_DIR/RELEASE-NOTES.md" ]]; then
  cp "$RELEASE_DIR/RELEASE-NOTES.md" "$UPLOAD_DIR/更新说明-发布页正文.md"
  chmod 644 "$UPLOAD_DIR/更新说明-发布页正文.md"
else
  echo "警告：找不到 $RELEASE_DIR/RELEASE-NOTES.md，上传目录里没有发布页文案。" >&2
fi

# 哈希清单 + 上传清单（每次打包现算，手写迟早对不上）。
(
  cd "$UPLOAD_DIR"
  shasum -a 256 *.zip *.tar.xz *.txt 7zz > SHA256SUMS
  {
    echo "# $VERSION 上传清单"
    echo
    echo "上传到 GitHub Release 的附件是本目录下的这些文件；"
    echo "\`README.md\`、\`SHA256SUMS\`、\`更新说明-发布页正文.md\` 都不作为附件上传"
    echo "（更新说明是粘贴到发布页「正文」里的）。"
    echo
    echo "| 附件 | 用途 | SHA-256 |"
    echo "| --- | --- | --- |"
    printf '| `Simple Unzip.zip` | 应用本体（版本 %s，内含 7zz 与全部许可原文） | `%s` |\n' \
      "$VERSION" "$(shasum -a 256 'Simple Unzip.zip' | awk '{print $1}')"
    printf '| `7zz` | 7-Zip 引擎，与应用包内那份是同一个二进制 | `%s` |\n' \
      "$(shasum -a 256 7zz | awk '{print $1}')"
    if [[ -f 7z2603-src.tar.xz ]]; then
      printf '| `7z2603-src.tar.xz` | 随包源码（LGPL 要求一并提供） | `%s` |\n' \
        "$(shasum -a 256 7z2603-src.tar.xz | awk '{print $1}')"
    fi
    printf '| `7-Zip-License.txt` | 7-Zip 各组件的许可说明 | `%s` |\n' \
      "$(shasum -a 256 7-Zip-License.txt | awk '{print $1}')"
    printf '| `LGPL-2.1.txt` | GNU LGPL 2.1 全文（FSF 官方原文） | `%s` |\n' \
      "$(shasum -a 256 LGPL-2.1.txt | awk '{print $1}')"
    printf '| `unRarLicense.txt` | unRAR 代码许可 | `%s` |\n' \
      "$(shasum -a 256 unRarLicense.txt | awk '{print $1}')"
    printf '| `Simple-Unzip-LICENSE.txt` | 本应用自身代码的 MIT 许可 | `%s` |\n' \
      "$(shasum -a 256 Simple-Unzip-LICENSE.txt | awk '{print $1}')"
    echo
    echo "## 自行核验哈希"
    echo
    echo '```bash'
    echo "cd release-for-github/upload-$VERSION    # 在仓库根目录执行"
    echo "shasum -a 256 -c SHA256SUMS"
    echo '```'
    echo
    echo "许可原文均从官网取得（LGPL 来自 gnu.org，两个 7-Zip 文件取自官方源码包），"
    echo "可用 \`scripts/fetch-licenses.sh\` 重新下载比对；该脚本里登记了同样的哈希，"
    echo "与上游不一致时会直接失败。"
  } > README.md
)

echo "上传件：$UPLOAD_DIR"
ls -l "$UPLOAD_DIR"
echo
echo "旧版本补挂件（单独一个文件）：$RELEASE_DIR/LGPL-2.1.txt"
shasum -a 256 "$RELEASE_DIR/LGPL-2.1.txt"
echo
shasum -a 256 "$OUTPUT"
