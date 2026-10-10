#!/bin/bash
# 开发模式：编译并前台运行（断开终端即退出）。产物在 .build，不组装 .app。
#
#   ./scripts/run.sh              # 正常运行（带菜单栏图标，悬浮刘海出面板）
#   ./scripts/run.sh --selftest   # 无头自检
#   ./scripts/run.sh --benchmark 45   # 报告自身开销
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$LITESTATS_ROOT"

swift build "${LITESTATS_FLAGS[@]}" --product LiteStats
BIN_DIR="$(litestats_bin_dir debug)"

exec "$BIN_DIR/LiteStats" "$@"
