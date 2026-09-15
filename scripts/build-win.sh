#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

echo "→ 生成图标"
swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources/icon.png"
ICONDIR="$ROOT/.build/icons"
mkdir -p "$ICONDIR"
for s in 16 32 48 256; do
  sips -z $s $s "$ROOT/Resources/icon.png" --out "$ICONDIR/icon_${s}.png" >/dev/null
done
python3 "$ROOT/scripts/pack_ico.py" "$ROOT/win/app.ico" \
  16:"$ICONDIR/icon_16.png" \
  32:"$ICONDIR/icon_32.png" \
  48:"$ICONDIR/icon_48.png" \
  256:"$ICONDIR/icon_256.png"
cp "$ICONDIR/icon_256.png" "$ROOT/win/icon.png"

cd "$ROOT/win"

echo "→ Windows 版协议自检（本机）"
go test ./protocol ./engine
go run . --selftest

echo "→ 嵌入 Windows 图标和公司信息"
rm -f rsrc_windows_amd64.syso rsrc_windows_386.syso rsrc_windows_arm64.syso
if go run github.com/tc-hib/go-winres@v0.3.3 make --arch amd64 --in winres.json; then
  :
else
  echo "改用简易方式嵌入图标"
  go run github.com/akavel/rsrc@v0.10.2 -arch amd64 -ico app.ico -o rsrc_windows_amd64.syso
fi

echo "→ 交叉编译 Windows 64 位"
mkdir -p "$ROOT/.build/win"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-H windowsgui -s -w" -o "$ROOT/.build/win/互传.exe"
rm -f rsrc_windows_amd64.syso rsrc_windows_386.syso rsrc_windows_arm64.syso

echo "完成：$ROOT/.build/win/互传.exe"
echo "把这个文件拷到 Windows 电脑，双击运行。请允许防火墙访问，并和 Mac 连同一个 Wi-Fi。"
echo "点 X 会收到右下角，不占任务栏。要退出请右击托盘图标，选「退出互传」。"
