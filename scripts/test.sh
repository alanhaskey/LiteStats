#!/bin/bash
# 跑单元测试 + 泄漏压测。
#
#   ./scripts/test.sh                 # 全部
#   ./scripts/test.sh --filter CPU    # 只跑匹配的
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$LITESTATS_ROOT"

swift test "${LITESTATS_FLAGS[@]}" "$@"
