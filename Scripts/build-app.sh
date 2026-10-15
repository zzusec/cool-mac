#!/bin/bash
set -euo pipefail
[[ "$EUID" -ne 0 ]] || { printf '请以普通用户构建，禁止 sudo/root。\n' >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/installer/build-support.sh"
[[ "$#" -eq 0 ]] || fail '用法：Scripts/build-app.sh（只构建，不安装或启动）'
acquire_lock

# Explicit CLT selection; do not mutate the machine's xcode-select setting.
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
[[ -d "$DEVELOPER_DIR" ]] || fail '未找到本机 Command Line Tools。'
SWIFT_VERSION="$(/usr/bin/xcrun swift --version)"
[[ "$SWIFT_VERSION" == *'Swift version 6.'* ]] || fail "要求 Swift 6：$SWIFT_VERSION"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
STAGE="$STAGING/app-build"
remove_generated "$STAGE"
/bin/mkdir -p "$STAGE"
printf '使用 CLT Swift 6、arm64、release、jobs=2 构建。\n'
/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$STAGE/swift-build" \
    --configuration release --arch arm64 --jobs 2
BIN_DIR="$(/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$STAGE/swift-build" \
    --configuration release --arch arm64 --jobs 2 --show-bin-path)"

BUILT_APP="$STAGE/$APP_NAME"
/bin/mkdir -p "$BUILT_APP/Contents/MacOS" "$BUILT_APP/Contents/Helpers" "$BUILT_APP/Contents/Resources"
/usr/bin/install -m 644 "$INFO" "$BUILT_APP/Contents/Info.plist"
/usr/bin/install -m 755 "$BIN_DIR/CoolMac" "$BUILT_APP/Contents/MacOS/CoolMac"
/usr/bin/install -m 755 "$BIN_DIR/CoolMacHelper" "$BUILT_APP/Contents/Helpers/CoolMacHelper"
/usr/bin/install -m 755 "$BIN_DIR/coolmacctl" "$BUILT_APP/Contents/Helpers/coolmacctl"
/usr/bin/install -m 755 "$BIN_DIR/CoolMacInstallTool" "$BUILT_APP/Contents/Helpers/CoolMacInstallTool"
/usr/bin/install -m 644 "$ROOT/Resources/使用说明.txt" "$BUILT_APP/Contents/Resources/使用说明.txt"
[[ -f "$ROOT/THIRD_PARTY_NOTICES.md" && ! -L "$ROOT/THIRD_PARTY_NOTICES.md" ]] || fail '缺少主代理维护的 THIRD_PARTY_NOTICES.md。'
/usr/bin/install -m 644 "$ROOT/THIRD_PARTY_NOTICES.md" "$BUILT_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Clear ACLs only on our newly assembled bundle, never on system directories.
/bin/chmod -RN "$BUILT_APP"

# Sign inside-out. No --deep signing, no permissive entitlements, no further edits to sealed contents.
/usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --identifier "$SERVICE" "$BUILT_APP/Contents/Helpers/CoolMacHelper"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --identifier 'local.hx10.coolmac.cli' "$BUILT_APP/Contents/Helpers/coolmacctl"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --identifier 'local.hx10.coolmac.install' "$BUILT_APP/Contents/Helpers/CoolMacInstallTool"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$BUILT_APP"
verify_app "$BUILT_APP"
printf '最终 GUI CDHash：%s\n' "$(cdhash "$BUILT_APP")"
printf '最终 CLI CDHash：%s\n' "$(cdhash "$BUILT_APP/Contents/Helpers/coolmacctl")"
# diagnose only reads sensors. Never execute the helper or a controlling CLI operation here.
"$BUILT_APP/Contents/Helpers/coolmacctl" diagnose > "$STAGE/diagnose.json"
# plutil -lint expects a property list; explicitly parse JSON through conversion first.
/usr/bin/plutil -convert xml1 -o "$STAGE/diagnose.plist" "$STAGE/diagnose.json"
/usr/bin/plutil -lint "$STAGE/diagnose.plist"

# Publish only a fully verified candidate; failed builds leave the previous output untouched.
remove_generated "$APP"
/bin/mv "$BUILT_APP" "$APP"
publish_file "$STAGE/diagnose.json" "$DIST/diagnose.json"
remove_generated "$STAGE"
printf '应用已构建并严格验证：%s\n仅构建；未安装、未启动 GUI/服务、未写入 SMC。\n' "$APP"
