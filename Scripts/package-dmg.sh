#!/bin/bash
set -euo pipefail
[[ "$EUID" -ne 0 ]] || { printf '请以普通用户打包，禁止 sudo/root。\n' >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/installer/build-support.sh"
case "${1:-}" in
    '') [[ "$#" -eq 0 ]] || fail '用法：Scripts/package-dmg.sh [--skip-build]'; "$SCRIPT_DIR/build-app.sh" ;;
    --skip-build) [[ "$#" -eq 1 ]] || fail '用法：Scripts/package-dmg.sh [--skip-build]' ;;
    *) fail '用法：Scripts/package-dmg.sh [--skip-build]' ;;
esac
acquire_lock
verify_app "$APP"
STAGE="$STAGING/package-build"
remove_generated "$STAGE"
PAYLOAD="$STAGE/payload"
INSTALLED_APP="$PAYLOAD/Applications/$APP_NAME"
INSTALLED_HELPER="$PAYLOAD$HELPER_PATH"
INSTALLED_INSTALL_TOOL="$PAYLOAD$INSTALL_TOOL_PATH"
MANIFEST="$PAYLOAD$MANIFEST_PATH"
/bin/mkdir -p "$PAYLOAD/Applications" "$PAYLOAD/Library/PrivilegedHelperTools" \
    "$PAYLOAD/Library/Application Support/CoolMac" "$PAYLOAD/Library/LaunchDaemons"
/usr/bin/ditto --noextattr --norsrc --noqtn --noacl "$APP" "$INSTALLED_APP"
/usr/bin/install -m 755 "$INSTALLED_APP/Contents/Helpers/CoolMacHelper" "$INSTALLED_HELPER"
/usr/bin/install -m 755 "$INSTALLED_APP/Contents/Helpers/CoolMacInstallTool" "$INSTALLED_INSTALL_TOOL"
/usr/bin/install -m 644 "$ROOT/Resources/$SERVICE.plist" "$PAYLOAD/Library/LaunchDaemons/$SERVICE.plist"

# Identities come from the final signed payload, never from unsigned .build files or user input.
CLIENT_HASH="$(cdhash "$INSTALLED_APP")"
CLI_HASH="$(cdhash "$INSTALLED_APP/Contents/Helpers/coolmacctl")"
/usr/bin/plutil -create xml1 "$MANIFEST"
/usr/bin/plutil -insert authorizedUID -integer 501 "$MANIFEST"
/usr/bin/plutil -insert clientCDHashes -json "[\"$CLIENT_HASH\"]" "$MANIFEST"
/usr/bin/plutil -insert cliCDHashes -json "[\"$CLI_HASH\"]" "$MANIFEST"
/usr/bin/plutil -lint "$MANIFEST"

# Package archive ownership is set by pkgbuild, without local chown/sudo.
# Remove inherited ACLs only from this newly created payload, never global /Library etc.
/bin/chmod -RN "$PAYLOAD"
/usr/bin/find "$PAYLOAD" -type d -exec /bin/chmod 755 {} +
/usr/bin/find "$PAYLOAD" -type f -exec /bin/chmod 644 {} +
/bin/chmod 755 "$INSTALLED_HELPER" "$INSTALLED_INSTALL_TOOL" "$INSTALLED_APP/Contents/MacOS/CoolMac" \
    "$INSTALLED_APP/Contents/Helpers/CoolMacHelper" "$INSTALLED_APP/Contents/Helpers/coolmacctl" \
    "$INSTALLED_APP/Contents/Helpers/CoolMacInstallTool"
verify_app "$INSTALLED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$INSTALLED_HELPER"
/usr/bin/codesign --verify --strict --verbose=2 "$INSTALLED_INSTALL_TOOL"
/usr/bin/cmp "$INSTALLED_HELPER" "$INSTALLED_APP/Contents/Helpers/CoolMacHelper"
/usr/bin/cmp "$INSTALLED_INSTALL_TOOL" "$INSTALLED_APP/Contents/Helpers/CoolMacInstallTool"
[[ "$(cdhash "$INSTALLED_APP")" == "$CLIENT_HASH" && "$(cdhash "$INSTALLED_APP/Contents/Helpers/coolmacctl")" == "$CLI_HASH" ]] || fail '签名身份在 payload 处理后改变。'
[[ "$(cdhash "$APP")" == "$CLIENT_HASH" && "$(cdhash "$APP/Contents/Helpers/coolmacctl")" == "$CLI_HASH" ]] || fail 'app 与 payload 身份不一致。'

INSTALL_SCRIPTS="$STAGE/installer-scripts"
/bin/mkdir -p "$INSTALL_SCRIPTS"
for script in preinstall postinstall; do
    /usr/bin/install -m 755 "$ROOT/Scripts/installer/$script" "$INSTALL_SCRIPTS/$script"
    /bin/bash -n "$INSTALL_SCRIPTS/$script"
done
/bin/chmod -RN "$INSTALL_SCRIPTS"
/usr/bin/xmllint --nonet --noout "$ROOT/Scripts/installer/Distribution.xml"
COMPONENT="$STAGE/CoolMacComponent.pkg"
/usr/bin/pkgbuild --root "$PAYLOAD" --identifier 'local.hx10.coolmac.pkg' --version "$VERSION" \
    --install-location / --ownership recommended --component-plist "$ROOT/Scripts/installer/components.plist" \
    --scripts "$INSTALL_SCRIPTS" "$COMPONENT"

# Check actual archived ownership/permissions, not the user's on-disk staging ownership.
/usr/sbin/pkgutil --expand "$COMPONENT" "$STAGE/component-expanded"
BOM="$STAGE/component-expanded/Bom"
[[ -f "$BOM" ]] || fail '安装包缺少 Bom。'
bom_entries="$(/usr/bin/lsbom -p fmug "$BOM")" || fail '无法读取安装包 Bom。'
count=0; helper_seen=0; manifest_seen=0; daemon_seen=0; app_seen=0; install_tool_seen=0
while IFS=$'\t' read -r path mode uid gid; do
    [[ "$uid" == '0' && "$gid" == '0' && "$mode" =~ ^[0-7]+$ ]] || fail "payload 不为 root:wheel：$path"
    (( (8#$mode & 8#22) == 0 )) || fail "payload 允许非 root 写入：$path"
    kind=$((8#$mode & 8#170000))
    [[ "$kind" -eq $((8#100000)) || "$kind" -eq $((8#40000)) ]] || fail "payload 含链接或特殊文件：$path"
    case "$path" in
        "./Library/PrivilegedHelperTools/$SERVICE") [[ "$mode" == '100755' ]] || fail 'helper 不是 755。'; helper_seen=1 ;;
        './Library/PrivilegedHelperTools/local.hx10.coolmac.install') [[ "$mode" == '100755' ]] || fail '更新安装工具不是 755。'; install_tool_seen=1 ;;
        './Library/Application Support/CoolMac/identity.plist') [[ "$mode" == '100644' ]] || fail 'manifest 不是 644。'; manifest_seen=1 ;;
        "./Library/LaunchDaemons/$SERVICE.plist") [[ "$mode" == '100644' ]] || fail 'LaunchDaemon 不是 644。'; daemon_seen=1 ;;
        "./Applications/$APP_NAME/Contents/MacOS/CoolMac") [[ "$mode" == '100755' ]] || fail 'GUI 不是 755。'; app_seen=1 ;;
    esac
    count=$((count + 1))
done <<< "$bom_entries"
[[ "$count" -gt 10 && "$helper_seen:$manifest_seen:$daemon_seen:$app_seen:$install_tool_seen" == '1:1:1:1:1' ]] || fail '安装包关键 payload 不完整。'
printf 'Bom 已验证：%s 项均为 root:wheel、不可由非 root 写入；helper=755、plist/manifest=644。\n' "$count"

BUILT_PKG="$STAGE/安装清凉风扇.pkg"
/usr/bin/productbuild --distribution "$ROOT/Scripts/installer/Distribution.xml" \
    --package-path "$STAGE" --resources "$ROOT/Resources/installer" "$BUILT_PKG"
# Also validate the real product archive after compression, without running its scripts.
/usr/sbin/pkgutil --expand-full "$BUILT_PKG" "$STAGE/product-expanded"
ARCHIVED_COMPONENT="$STAGE/product-expanded/CoolMacComponent.pkg"
ARCHIVED_APP="$ARCHIVED_COMPONENT/Payload/Applications/$APP_NAME"
verify_app "$ARCHIVED_APP"
/usr/bin/cmp "$ARCHIVED_COMPONENT/Bom" "$BOM"
/usr/bin/cmp "$ARCHIVED_COMPONENT/Payload$HELPER_PATH" "$INSTALLED_HELPER"
/usr/bin/cmp "$ARCHIVED_COMPONENT/Payload$MANIFEST_PATH" "$MANIFEST"
/usr/bin/cmp "$ARCHIVED_COMPONENT/Payload/Library/LaunchDaemons/$SERVICE.plist" "$ROOT/Resources/$SERVICE.plist"
for script in preinstall postinstall; do
    /usr/bin/cmp "$ARCHIVED_COMPONENT/Scripts/$script" "$INSTALL_SCRIPTS/$script"
done
[[ "$(cdhash "$ARCHIVED_APP")" == "$CLIENT_HASH" && "$(cdhash "$ARCHIVED_APP/Contents/Helpers/coolmacctl")" == "$CLI_HASH" ]] || fail '压缩后的安装包代码身份改变。'
printf '实际 pkg 已展开验证：代码签名、manifest、LaunchDaemon 和安装脚本均匹配。\n'
DMG_CONTENTS="$STAGE/dmg-contents"
/bin/mkdir -p "$DMG_CONTENTS"
/usr/bin/ditto --noextattr --norsrc --noqtn --noacl "$APP" "$DMG_CONTENTS/$APP_NAME"
/usr/bin/install -m 644 "$BUILT_PKG" "$DMG_CONTENTS/安装清凉风扇.pkg"
/usr/bin/install -m 644 "$ROOT/Resources/使用说明.txt" "$DMG_CONTENTS/使用说明.txt"
/bin/ln -s /Applications "$DMG_CONTENTS/Applications"
BUILT_DMG="$STAGE/清凉风扇-$VERSION-arm64.dmg"
/usr/bin/hdiutil create -volname '清凉风扇' -srcfolder "$DMG_CONTENTS" -format UDZO -fs HFS+ "$BUILT_DMG"
/usr/bin/hdiutil verify "$BUILT_DMG"

# Inspect the actual image read-only; detach on every exit. No installation or GUI launch.
MOUNT="$STAGE/mounted-dmg"
MOUNTED=0
package_cleanup() {
    local status=$?
    if [[ "$MOUNTED" -eq 1 ]]; then
        if ! /usr/bin/hdiutil detach "$MOUNT"; then
            printf '错误：候选 DMG 未能卸载，请检查 %s\n' "$MOUNT" >&2
            status=1
        fi
    fi
    release_lock
    exit "$status"
}
trap package_cleanup EXIT
/bin/mkdir "$MOUNT"
# Mark before attaching so even a partially successful attach gets a detach attempt.
MOUNTED=1
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$BUILT_DMG"
verify_app "$MOUNT/$APP_NAME"
[[ "$(/usr/bin/readlink "$MOUNT/Applications")" == '/Applications' ]] || fail 'DMG Applications 快捷方式不匹配。'
/usr/bin/cmp "$MOUNT/安装清凉风扇.pkg" "$BUILT_PKG"
/usr/bin/cmp "$MOUNT/使用说明.txt" "$ROOT/Resources/使用说明.txt"
[[ "$(cdhash "$MOUNT/$APP_NAME")" == "$CLIENT_HASH" && "$(cdhash "$MOUNT/$APP_NAME/Contents/Helpers/coolmacctl")" == "$CLI_HASH" ]] || fail 'DMG 最终签名与 manifest 不一致。'
/usr/bin/hdiutil detach "$MOUNT"
MOUNTED=0

remove_generated "$PKG"
remove_generated "$DMG"
/bin/mv "$BUILT_PKG" "$PKG"
/bin/mv "$BUILT_DMG" "$DMG"
publish_file "$MANIFEST" "$DIST/identity.plist"
remove_generated "$STAGE"
printf '候选 DMG 已打包并只读验证：%s\n安装包：%s\n未安装/启动服务。app 为 ad-hoc 签名；pkg 无证书签名；均未 Apple 公证。\n' "$DMG" "$PKG"
