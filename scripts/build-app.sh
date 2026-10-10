#!/bin/bash
# 组装 LiteStats.app（本机没有可用 Xcode 工具链，所以不能用 xcodebuild）
#
#   ./scripts/build-app.sh            # release
#   ./scripts/build-app.sh debug      # debug
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CONFIG="${1:-release}"
APP="$LITESTATS_ROOT/dist/LiteStats.app"
cd "$LITESTATS_ROOT"

echo "==> 编译 ($CONFIG)"
swift build "${LITESTATS_FLAGS[@]}" -c "$CONFIG" --product LiteStats

BIN_DIR="$(litestats_bin_dir "$CONFIG")"
if [[ ! -x "$BIN_DIR/LiteStats" ]]; then
  echo "找不到可执行文件：$BIN_DIR/LiteStats" >&2
  exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LiteStats" "$APP/Contents/MacOS/LiteStats"
cp "$LITESTATS_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$LITESTATS_ROOT/Resources/AppIcon.icns" ]]; then
  cp "$LITESTATS_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（ad-hoc）"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （ad-hoc 签名失败，不影响本机运行）"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2 || true

echo
echo "完成：$APP"
echo "启动：open \"$APP\""
echo "退出：pkill -f 'LiteStats.app/Contents/MacOS/LiteStats'（或点菜单栏图标 → 退出）"
echo "自检：\"$APP/Contents/MacOS/LiteStats\" --selftest --dump-render /tmp/litestats.png"
