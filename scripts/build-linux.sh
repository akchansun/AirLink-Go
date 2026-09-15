#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="1.0.0"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

cd "$ROOT/win"

echo "→ 本机协议自检"
go test ./protocol ./engine
go run . --selftest

echo "→ 交叉编译 Linux（amd64 / arm64，不含 CGO）"
mkdir -p "$ROOT/.build/linux"
for arch in amd64 arm64; do
  echo "  编译 linux/$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -ldflags="-s -w" -o "$ROOT/.build/linux/huchuan-$arch"
  STAGE="$(mktemp -d)"
  mkdir -p "$STAGE/互传"
  cp "$ROOT/.build/linux/huchuan-$arch" "$STAGE/互传/huchuan"
  chmod +x "$STAGE/互传/huchuan"
  cp "$ROOT/linux/启动互传.sh" "$STAGE/互传/启动互传.sh"
  chmod +x "$STAGE/互传/启动互传.sh"
  cp "$ROOT/linux/huchuan.desktop" "$STAGE/互传/huchuan.desktop"
  cp "$ROOT/linux/用法.txt" "$STAGE/互传/用法.txt"
  cp "$ROOT/Resources/icon.png" "$STAGE/互传/icon.png"
  tar -C "$STAGE" -czf "$ROOT/.build/linux/互传-${VERSION}-linux-${arch}.tar.gz" 互传
  rm -rf "$STAGE"
  echo "  完成：$ROOT/.build/linux/互传-${VERSION}-linux-${arch}.tar.gz"
done

file "$ROOT/.build/linux/huchuan-amd64" "$ROOT/.build/linux/huchuan-arm64"
echo "完成。"
