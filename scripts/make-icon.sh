#!/bin/bash
# 从 Resources/AppIcon-1024.png 生成 Resources/AppIcon.icns。
#
#   ./scripts/make-icon.sh
#
# 换图标时：把新的 1024×1024 PNG 覆盖到 Resources/AppIcon-1024.png，再跑这个脚本。
# 说明：macOS 图标规范里圆角方块约占画布 80%、四周留白约 10%；
# 当前这张图实测内容占 79.9%×81.3%、左右留白各 126px、上下 114/121px，正好合规，所以不做补边。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon-1024.png"
ICONSET="$ROOT/Resources/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

[[ -f "$SRC" ]] || { echo "缺少源图：$SRC" >&2; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# 需要 @1x 与 @2x 两套，共 10 个尺寸
render() { sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "已生成：${OUT}（$(du -h "$OUT" | cut -f1)）"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2
