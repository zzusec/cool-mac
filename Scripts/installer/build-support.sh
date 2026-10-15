#!/bin/bash
# Build-time support only. This file is never included in Installer's scripts.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || fail '构建脚本禁止以 root 运行；请以普通用户构建，安装另走 macOS Installer。'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$ROOT" == '/Users/hx10/cool-mac' ]] || fail '项目路径不是固定的 /Users/hx10/cool-mac，拒绝删除或打包。'
DIST="$ROOT/dist"
STAGING="$DIST/.staging"
APP_NAME='清凉风扇.app'
APP="$DIST/$APP_NAME"
SERVICE='local.hx10.coolmac.helper'
HELPER_PATH='/Library/PrivilegedHelperTools/local.hx10.coolmac.helper'
INSTALL_TOOL_PATH='/Library/PrivilegedHelperTools/local.hx10.coolmac.install'
MANIFEST_PATH='/Library/Application Support/CoolMac/identity.plist'
INFO="$ROOT/Resources/Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Info.plist 版本必须是 x.y.z：$VERSION"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "Info.plist CFBundleVersion 必须是单调递增整数：$BUILD"
PKG="$DIST/安装清凉风扇.pkg"
DMG="$DIST/清凉风扇-$VERSION-arm64.dmg"

ensure_directory() {
    local path="$1"
    [[ ! -L "$path" ]] || fail "拒绝符号链接目录：$path"
    [[ ! -e "$path" || -d "$path" ]] || fail "不是目录：$path"
    /bin/mkdir -p "$path"
}
check_workspace() {
    [[ "$(cd -- "$ROOT" && pwd -P)" == "$ROOT" ]] || fail '项目真实路径发生变化。'
    [[ -d "$DIST" && ! -L "$DIST" && -d "$STAGING" && ! -L "$STAGING" ]] || fail 'dist/staging 必须为本项目真实目录。'
    [[ "$(cd -- "$DIST" && pwd -P)" == "$ROOT/dist" ]] || fail 'dist 超出本项目。'
    [[ "$(cd -- "$STAGING" && pwd -P)" == "$ROOT/dist/.staging" ]] || fail 'staging 超出本项目。'
}
# Do not broaden this allowlist or accept caller-supplied output directories.
remove_generated() {
    local path="$1"
    check_workspace
    case "$path" in
        "$STAGING/app-build"|"$STAGING/package-build"|"$APP"|"$PKG"|"$DMG") ;;
        *) fail "拒绝清理非固定产物：$path" ;;
    esac
    [[ ! -L "$path" ]] || fail "拒绝删除符号链接产物：$path"
    if [[ -e "$path" ]]; then /bin/rm -rf -- "$path"; fi
}
publish_file() {
    local source="$1" destination="$2"
    check_workspace
    case "$destination" in "$DIST/diagnose.json"|"$DIST/identity.plist") ;; *) fail "拒绝写入非固定产物：$destination" ;; esac
    [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || fail "输出文件类型不安全：$destination"
    /bin/mv -f -- "$source" "$destination"
}
acquire_lock() {
    check_workspace
    LOCK="$STAGING/packaging.lock"
    /bin/mkdir "$LOCK" 2>/dev/null || fail "打包锁已存在：$LOCK；确认没有构建进程后才能手动移除此空目录。"
    trap 'release_lock' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
release_lock() {
    if [[ -n "${LOCK:-}" && -d "$LOCK" && ! -L "$LOCK" ]]; then
        /bin/rmdir "$LOCK" || printf '警告：未能移除打包锁 %s\n' "$LOCK" >&2
    fi
}
cdhash() {
    local path="$1" details line hash='' count=0
    details="$(/usr/bin/codesign -d --verbose=4 --arch arm64 "$path" 2>&1)" || fail "不能读取最终签名：$path"
    while IFS= read -r line; do
        case "$line" in
            CDHash=*) hash="${line#CDHash=}"; count=$((count + 1)) ;;
        esac
    done <<< "$details"
    [[ "$count" -eq 1 && "$hash" =~ ^[0-9a-fA-F]{40}$ ]] || fail "没有唯一 arm64 CDHash：$path"
    printf '%s\n' "$hash"
}
verify_app() {
    local app="$1" binary details entitlements deployment
    [[ -d "$app" && ! -L "$app" ]] || fail "应用缺失或为符号链接：$app"
    /usr/bin/plutil -lint "$app/Contents/Info.plist"
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" == 'local.hx10.coolmac' ]] || fail '应用标识不匹配。'
    [[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")" == 'CoolMac' ]] || fail '应用可执行文件不匹配。'
    [[ "$(/usr/bin/plutil -extract LSUIElement raw -o - "$app/Contents/Info.plist")" == 'true' ]] || fail 'LSUIElement 必须为 true。'
    [[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")" == '14.0' ]] || fail '应用最低系统版本必须为 macOS 14。'
    [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "$VERSION" ]] || fail '应用版本不匹配，请重新构建。'
    for binary in "$app/Contents/MacOS/CoolMac" "$app/Contents/Helpers/CoolMacHelper" "$app/Contents/Helpers/coolmacctl" "$app/Contents/Helpers/CoolMacInstallTool"; do
        [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || fail "可执行文件缺失或不安全：$binary"
        [[ "$(/usr/bin/lipo -archs "$binary")" == 'arm64' ]] || fail "不是纯 arm64：$binary"
        deployment="$(/usr/bin/vtool -show-build "$binary")" || fail "无法读取部署目标：$binary"
        /usr/bin/grep -Eq '^[[:space:]]*platform MACOS$' <<< "$deployment" || fail "不是 macOS 可执行文件：$binary"
        /usr/bin/grep -Eq '^[[:space:]]*minos 14\.0$' <<< "$deployment" || fail "最低部署版本不是 macOS 14：$binary"
        /usr/bin/codesign --verify --strict --verbose=2 "$binary"
        details="$(/usr/bin/codesign -d --verbose=4 --arch arm64 "$binary" 2>&1)" || fail "无法检查签名标志：$binary"
        /usr/bin/grep -E '^CodeDirectory .*flags=.*runtime' <<< "$details" >/dev/null || fail "缺少 Hardened Runtime：$binary"
        entitlements="$(/usr/bin/codesign -d --entitlements - "$binary")" || fail "不能读取 entitlements：$binary"
        [[ -z "$entitlements" ]] || fail "本地构建不允许额外 entitlements：$binary"
    done
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
}

ensure_directory "$DIST"
ensure_directory "$STAGING"
/usr/bin/plutil -lint "$INFO" "$ROOT/Resources/local.hx10.coolmac.helper.plist" \
    "$ROOT/Scripts/installer/components.plist"
# Fail rather than silently packaging identities or paths inconsistent with the source.
MODELS="$ROOT/Sources/CoolMacCore/Models.swift"
for definition in \
    'public static let name = "清凉风扇"' \
    "public static let version = \"$VERSION\"" \
    "public static let build = $BUILD" \
    'public static let bundleID = "local.hx10.coolmac"' \
    'public static let service = "local.hx10.coolmac.helper"' \
    'public static let helperPath = "/Library/PrivilegedHelperTools/local.hx10.coolmac.helper"' \
    'public static let manifestPath = "/Library/Application Support/CoolMac/identity.plist"'; do
    /usr/bin/grep -Fq "$definition" "$MODELS" || fail "版本或安装契约改变，需同步 Product 与打包脚本：$definition"
done
# The installer metadata must agree with the app it installs.
/usr/bin/grep -Fq "version=\"$VERSION\"" "$ROOT/Scripts/installer/Distribution.xml" \
    || fail "Distribution.xml 版本与 Info.plist 不一致（应为 $VERSION）。"
