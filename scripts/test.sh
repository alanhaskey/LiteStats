#!/bin/bash
# 跑单元测试 + 泄漏压测。
#
# 本机环境有两个坑，脚本里已经处理：
#   1. SwiftPM 的 sandbox-exec 不可用 → --disable-sandbox
#   2. swift-testing 的宏插件路径有时解析不到（报 "plugin for module 'TestingMacros' not found"）
#      → 显式把 -plugin-path 传给 swiftc
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_PATH="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

cd "$ROOT"
swift test --disable-sandbox --scratch-path "$ROOT/.build" \
  -Xswiftc -plugin-path -Xswiftc "$PLUGIN_PATH" "$@"
