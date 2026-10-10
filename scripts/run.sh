#!/bin/bash
# 开发模式：编译并前台运行（断开终端即退出）。产物在 .build，不组装 .app。
#
#   ./scripts/run.sh              # 正常运行（带菜单栏图标，悬浮刘海出面板）
#   ./scripts/run.sh --selftest   # 无头自检
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --disable-sandbox --scratch-path "$ROOT/.build" --product LiteStats
BIN_DIR="$(swift build --disable-sandbox --scratch-path "$ROOT/.build" --show-bin-path | tail -1)"

exec "$BIN_DIR/LiteStats" "$@"
