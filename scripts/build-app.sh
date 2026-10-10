#!/bin/bash
# 组装 LiteStats.app（本机只有 Command Line Tools，没有 Xcode，所以不能用 xcodebuild）
#
#   ./scripts/build-app.sh            # release
#   ./scripts/build-app.sh debug      # debug
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
SCRATCH="$ROOT/.build"
APP="$ROOT/dist/LiteStats.app"

cd "$ROOT"

echo "==> 编译 ($CONFIG)"
# --disable-sandbox 是必须的：SwiftPM 的 sandbox-exec 在受限环境下无法 apply
swift build --disable-sandbox --scratch-path "$SCRATCH" -c "$CONFIG" --product LiteStats

BIN_DIR="$(swift build --disable-sandbox --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path | tail -1)"
if [[ ! -x "$BIN_DIR/LiteStats" ]]; then
  echo "找不到可执行文件：$BIN_DIR/LiteStats" >&2
  exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LiteStats" "$APP/Contents/MacOS/LiteStats"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（ad-hoc）"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （ad-hoc 签名失败，不影响本机运行）"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2 || true

echo
echo "完成：$APP"
echo "启动：open \"$APP\""
echo "退出：pkill -f 'LiteStats.app/Contents/MacOS/LiteStats'（或点菜单栏图标 → 退出）"
echo "自检：\"$APP/Contents/MacOS/LiteStats\" --selftest --dump-render /tmp/litestats.png"
