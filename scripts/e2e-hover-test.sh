#!/bin/bash
# 端到端悬浮测试：程序化移动光标，验证「悬浮刘海 → 展开 → 移开 → 收起」整条链路。
#
# ⚠️ 会短暂移动你的鼠标光标，测试结束后自动还原到原位置。
#    之所以要这么测：本机没有屏幕录制权限，无法截图看画面；
#    把 App 的状态机切换写进日志、再用光标驱动它，是唯一能自动化验证交互的办法。
#
#   ./scripts/e2e-hover-test.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROOT="$LITESTATS_ROOT"
TRACE="$(mktemp -t litestats-trace).log"
WARP="$(mktemp -d)/cursor-warp"
cd "$ROOT"

echo "==> 编译"
swift build "${LITESTATS_FLAGS[@]}" --product LiteStats >/dev/null
BIN_DIR="$(litestats_bin_dir debug)"
swiftc -O -module-cache-path "$(mktemp -d)" -o "$WARP" "$ROOT/tools/cursor-warp.swift" -framework CoreGraphics

APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "${ORIGINAL_CURSOR:-}" ]] && "$WARP" $ORIGINAL_CURSOR >/dev/null 2>&1 || true
}
trap cleanup EXIT

ORIGINAL_CURSOR="$("$WARP" get)"
echo "==> 原始光标位置：$ORIGINAL_CURSOR"

echo "==> 启动 LiteStats（--trace ${TRACE}）"
"$BIN_DIR/LiteStats" --trace "$TRACE" &
APP_PID=$!
sleep 2.0

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "FAIL: 应用启动后立刻退出" >&2
  cat "$TRACE" 2>/dev/null || true
  exit 1
fi

# 坐标可能是负数（外接显示器时内置刘海屏的原点不是 0,0），所以正则要允许负号
NOTCH_POINT="$(grep -o 'notchCenterCG -\?[0-9.]* -\?[0-9.]*' "$TRACE" | tail -1 | cut -d' ' -f2,3 || true)"
if [[ -z "$NOTCH_POINT" ]]; then
  echo "FAIL: 日志里没有 notchCenterCG（该屏幕可能没有刘海，回退模式下不适用本测试）" >&2
  cat "$TRACE"
  exit 1
fi
echo "==> 刘海中心（CG 坐标）：$NOTCH_POINT"

echo "==> 把光标移到刘海上"
"$WARP" $NOTCH_POINT >/dev/null
sleep 1.2

echo "==> 光标移到屏幕中部（应触发收起）"
"$WARP" 900 600 >/dev/null
sleep 1.6

echo "==> 还原光标"
"$WARP" $ORIGINAL_CURSOR >/dev/null
sleep 0.6

kill "$APP_PID" 2>/dev/null || true
APP_PID=""
sleep 0.3

echo
echo "==> 状态机日志"
cat "$TRACE"

expanded=$(grep -c 'state=expanded' "$TRACE" || true)
collapsed=$(grep -c 'state=collapsed' "$TRACE" || true)
echo
if [[ "$expanded" -ge 1 && "$collapsed" -ge 1 ]]; then
  echo "E2E RESULT: PASS（展开 $expanded 次 / 收起 $collapsed 次）"
  exit 0
fi
echo "E2E RESULT: FAIL（展开 $expanded 次 / 收起 $collapsed 次）" >&2
exit 1
