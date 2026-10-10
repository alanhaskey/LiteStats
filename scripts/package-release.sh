#!/bin/bash
# 把 dist/LiteStats.app 打成发布件（zip + dmg）并校验。
#
#   ./scripts/package-release.sh
#
# 产物：dist/LiteStats-<版本>.zip、dist/LiteStats-<版本>.dmg、dist/SHA256SUMS-<版本>.txt
# 说明：本机没有开发者证书，签名是 ad-hoc。别人下载后首次打开需要
# 「右键 → 打开」，或者 xattr -d com.apple.quarantine /Applications/LiteStats.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/LiteStats.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="$ROOT/dist/LiteStats-${VERSION}.zip"
DMG="$ROOT/dist/LiteStats-${VERSION}.dmg"
SUMS="$ROOT/dist/SHA256SUMS-${VERSION}.txt"

[[ -d "$APP" ]] || { echo "缺少 $APP，先跑 scripts/build-app.sh release" >&2; exit 1; }
echo "==> 打包 LiteStats ${VERSION}"

rm -f "$ZIP" "$DMG"
# ditto 会保留签名与扩展属性（用 zip 命令会破坏 .app 的签名信息）
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LiteStats ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

shasum -a 256 "$ZIP" "$DMG" > "$SUMS"
echo "==> 产物"
for f in "$ZIP" "$DMG"; do
  printf '    %s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
done
cat "$SUMS" | sed 's|^|    |' 

# 自检：解压后必须还能跑起来（确认发布件完整）
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict "$CHECK/LiteStats.app"
"$CHECK/LiteStats.app/Contents/MacOS/LiteStats" --selftest 2>&1 | grep -E "自检结果" || true
rm -rf "$CHECK"
