#!/bin/bash
# 权威的泄漏检查：把传感器层和这个压测程序**单独编译成一个进程**跑，
# 避免单元测试并行执行时（温度测试会做 HID/SMC 发现、分配几 MB）把 RSS 测歪。
#
#   ./scripts/soak.sh              # 全部传感器各 20000 拍
#   ./scripts/soak.sh cpu 50000    # 只压 CPU，5 万拍
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$LITESTATS_ROOT"

TARGET="${1:-all}"
ITERATIONS="${2:-20000}"
OUT="$(mktemp -d)/litestats-soak"

echo "==> 编译（传感器层 + tools/soak/main.swift，单进程）"
swiftc -O -module-cache-path "$(mktemp -d)" \
  -o "$OUT" \
  Sources/LiteStatsCore/*.swift tools/soak/main.swift \
  -framework IOKit -framework SystemConfiguration

echo "==> 压测：目标=$TARGET 拍数=$ITERATIONS"
if [[ "$TARGET" == "all-sensors" ]]; then
  for sensor in cpu mem net gpu disk all; do
    "$OUT" "$sensor" "$ITERATIONS"
  done
else
  "$OUT" "$TARGET" "$ITERATIONS"
fi

echo
echo "判读：每拍增长应是个位数到几十字节的分配器噪声；"
echo "     把拍数翻几倍，如果 B/拍 不降反升且接近某个固定值（例如 240 = host_processor_info 的 tick 缓冲），才是真泄漏。"
