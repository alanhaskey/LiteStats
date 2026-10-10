#!/bin/bash
# 各脚本共用的环境适配。用 `source` 引入，不要直接执行。
#
# 本机环境的两个坑：
#   1. SwiftPM 的 sandbox-exec 在受限环境下无法 apply → 所有 swift 命令都要 --disable-sandbox
#   2. SwiftPM 有时解析不到宏插件路径（SwiftUI 的 @State/@Bindable 需要 SwiftUIMacros，
#      swift-testing 需要 TestingMacros），报 "plugin ... not found" → 显式把插件目录传给 swiftc
#
# 注意：工作目录路径里带空格，所以参数必须放进数组用 "${LITESTATS_FLAGS[@]}" 展开，
# 不能靠函数返回字符串再 $(...) 拼接（会在空格处被拆开）。
set -euo pipefail

LITESTATS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITESTATS_SCRATCH="$LITESTATS_ROOT/.build"

LITESTATS_FLAGS=(--disable-sandbox --scratch-path "$LITESTATS_SCRATCH")

for _dir in \
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
  "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins" \
  "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
do
  [[ -d "$_dir" ]] && LITESTATS_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$_dir") || true
done
unset _dir

# 编译产物目录
litestats_bin_dir() {
  local config="${1:-debug}"
  swift build "${LITESTATS_FLAGS[@]}" -c "$config" --show-bin-path | tail -1
}
