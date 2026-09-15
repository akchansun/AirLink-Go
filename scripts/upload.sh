#!/bin/zsh
# 把互传介绍页、下载页和安装包传到 www.ak129.cn
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${SITE_ROOT:-}"
if [[ -z "$SITE" ]]; then
  echo "请设置 SITE_ROOT 为静态站点目录（含 index.html、huchuan/ 等），例如："
  echo "  export SITE_ROOT=\"/path/to/static-home\""
  exit 1
fi
if [[ ! -d "$SITE" ]]; then
  echo "SITE_ROOT 不是目录: $SITE"
  exit 1
fi
CMS_HOST="${CMS_HOST:-ak129-vps}"
VERSION="1.0.0"
APP="$ROOT/.build/互传.app"
EXE="$ROOT/.build/win/互传.exe"
LINUX_AMD="$ROOT/.build/linux/互传-${VERSION}-linux-amd64.tar.gz"
LINUX_ARM="$ROOT/.build/linux/互传-${VERSION}-linux-arm64.tar.gz"

if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP，请先 zsh scripts/build.sh"
  exit 1
fi
if [[ ! -f "$EXE" ]]; then
  echo "找不到 $EXE，请先 zsh scripts/build-win.sh"
  exit 1
fi
if [[ ! -f "$LINUX_AMD" || ! -f "$LINUX_ARM" ]]; then
  echo "找不到 Linux 安装包，请先 zsh scripts/build-linux.sh"
  exit 1
fi

mkdir -p "$SITE/huchuan/images" "$SITE/huchuan/download"
sips -z 256 256 "$ROOT/Resources/icon.png" --out "$SITE/huchuan/images/icon.png" >/dev/null

STAGE="$(mktemp -d)"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$STAGE/互传-${VERSION}-mac.zip"
cp "$EXE" "$STAGE/互传-${VERSION}.exe"
cp "$LINUX_AMD" "$STAGE/互传-${VERSION}-linux-amd64.tar.gz"
cp "$LINUX_ARM" "$STAGE/互传-${VERSION}-linux-arm64.tar.gz"

echo "→ 上传页面"
ssh -o BatchMode=yes "$CMS_HOST" "mkdir -p /var/www/static-home/huchuan/download /var/www/static-home/huchuan/images"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/index.html" \
  "$SITE/sitemap.xml" \
  "$SITE/llms.txt" \
  "$CMS_HOST:/var/www/static-home/"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/images/x-logo.png" \
  "$CMS_HOST:/var/www/static-home/images/x-logo.png"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/fucai/index.html" "$CMS_HOST:/var/www/static-home/fucai/index.html"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/jifen/index.html" "$CMS_HOST:/var/www/static-home/jifen/index.html"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/jiaopei/index.html" "$CMS_HOST:/var/www/static-home/jiaopei/index.html"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/huchuan/index.html" "$CMS_HOST:/var/www/static-home/huchuan/index.html"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/huchuan/download/index.html" "$CMS_HOST:/var/www/static-home/huchuan/download/index.html"
rsync -avz -e "ssh -o BatchMode=yes" \
  "$SITE/huchuan/images/" "$CMS_HOST:/var/www/static-home/huchuan/images/"

echo "→ 上传安装包"
rsync -avz --progress -e "ssh -o BatchMode=yes" \
  "$STAGE/互传-${VERSION}-mac.zip" \
  "$STAGE/互传-${VERSION}.exe" \
  "$STAGE/互传-${VERSION}-linux-amd64.tar.gz" \
  "$STAGE/互传-${VERSION}-linux-arm64.tar.gz" \
  "$CMS_HOST:/var/www/static-home/huchuan/download/"

rm -rf "$STAGE"
echo "完成。"
echo "  介绍: https://www.ak129.cn/huchuan/"
echo "  下载: https://www.ak129.cn/huchuan/download/"
echo "  首页: https://www.ak129.cn/"
