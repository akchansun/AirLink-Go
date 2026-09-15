#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
echo "→ 编译正式版"
swift build -c release --product HuChuan

echo "→ 生成图标"
mkdir -p "$ROOT/Resources/AppIcon.iconset"
swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources/icon.png"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$ROOT/Resources/icon.png" --out "$ROOT/Resources/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$ROOT/Resources/icon.png" --out "$ROOT/Resources/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "→ 打包 .app"
APP="$ROOT/.build/互传.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/HuChuan" "$APP/Contents/MacOS/互传"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ROOT/Resources/Credits.rtf" ]; then
  cp "$ROOT/Resources/Credits.rtf" "$APP/Contents/Resources/Credits.rtf"
fi
echo -n "APPL????" > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/互传"
codesign -s - --force --deep "$APP" >/dev/null 2>&1 || true

echo "→ 回路自检（本机给本机传 24MB）"
"$APP/Contents/MacOS/互传" --selftest

echo "完成：$APP"
