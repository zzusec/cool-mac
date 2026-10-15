#!/bin/bash
# 清凉风扇发布编排：构建并校验 → 签名清单 → 确认后上传。
# 只做编排：打包复用 Scripts/package-dmg.sh，签名与上传交给 CoolMacRelease。
# 不执行 sudo，不安装、不启动任何东西，不上传目录、identity.plist 或任何私钥。
set -euo pipefail
[[ "$EUID" -ne 0 ]] || { echo '请以普通用户发布，禁止 sudo/root。' >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/installer/build-support.sh"

usage() {
    cat <<'EOF'
用法：Scripts/release.sh --version <x.y.z> --build <n> --notes <文件或文本> [--url <https://…>] [--yes] [--skip-build]

  --version    发布版本，必须与 Resources/Info.plist 的 CFBundleShortVersionString 一致
  --build      构建号（正整数，单调递增），必须与 CFBundleVersion 一致
  --notes      更新说明，可以是文件路径，也可以是字面文本
  --url        覆盖 assetURL；必须指向 zzusec/cool-mac 的 Release 资产
  --yes        跳过交互确认直接上传（仅用于无人值守）
  --skip-build 跳过 package-dmg.sh，直接使用 dist 中已有的产物

流程：Scripts/package-dmg.sh（构建并校验）→ 构建 CoolMacRelease → sign 写出 dist/update.json
      → 打印将上传的确切文件清单并确认 → publish（固定 /opt/homebrew/bin/gh，只上传 pkg、dmg、update.json）
EOF
}

VERSION_ARG=''
BUILD_ARG=''
NOTES_ARG=''
URL_ARG=''
CONFIRM=0
SKIP_BUILD=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --version)
            [[ "$#" -ge 2 ]] || { usage >&2; fail '--version 缺少取值'; }
            VERSION_ARG="$2"; shift 2 ;;
        --build)
            [[ "$#" -ge 2 ]] || { usage >&2; fail '--build 缺少取值'; }
            BUILD_ARG="$2"; shift 2 ;;
        --notes)
            [[ "$#" -ge 2 ]] || { usage >&2; fail '--notes 缺少取值'; }
            NOTES_ARG="$2"; shift 2 ;;
        --url)
            [[ "$#" -ge 2 ]] || { usage >&2; fail '--url 缺少取值'; }
            URL_ARG="$2"; shift 2 ;;
        --yes) CONFIRM=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "无法识别的参数：$1" ;;
    esac
done
if [[ -z "$VERSION_ARG" || -z "$BUILD_ARG" || -z "$NOTES_ARG" ]]; then
    usage >&2
    fail '必须同时提供 --version、--build、--notes'
fi
[[ "$VERSION_ARG" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] || fail "版本必须是点分数字（如 1.1 或 1.1.0）：$VERSION_ARG"
[[ "$BUILD_ARG" =~ ^[1-9][0-9]*$ ]] || fail "构建号必须是正整数：$BUILD_ARG"
[[ "$VERSION_ARG" == "$VERSION" ]] || fail "版本与 Resources/Info.plist 不一致（Info.plist=${VERSION}，参数=${VERSION_ARG}）"
PLIST_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO")"
[[ "$BUILD_ARG" == "$PLIST_BUILD" ]] || fail "构建号与 Resources/Info.plist 不一致（Info.plist=${PLIST_BUILD}，参数=${BUILD_ARG}）"
[[ -n "$NOTES_ARG" ]] || fail '--notes 不能为空'
if [[ -n "$URL_ARG" && "$URL_ARG" != https://* ]]; then
    fail "--url 必须是 https 地址：$URL_ARG"
fi

# 1) 构建并校验（复用既有打包脚本；它会构建、签名、打包并只读验证 DMG）
if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo '按 --skip-build 跳过打包，使用 dist 中已有产物。'
else
    "$SCRIPT_DIR/package-dmg.sh"
fi
for artifact in "$PKG" "$DMG"; do
    [[ -f "$artifact" && ! -L "$artifact" ]] || fail "缺少打包产物：$artifact"
done
echo "安装包：$PKG"
echo "DMG：$DMG"

# GitHub mangles non-ASCII upload filenames, so the release assets use fixed
# ASCII names. Content is identical; the manifest URL follows the ASCII name.
RELEASE_PKG="$DIST/CoolMac-$VERSION_ARG.pkg"
RELEASE_DMG="$DIST/CoolMac-$VERSION_ARG.dmg"
for pair in "$PKG:$RELEASE_PKG" "$DMG:$RELEASE_DMG"; do
    source_path="${pair%%:*}"
    target_path="${pair##*:}"
    [[ ! -L "$target_path" ]] || fail "发布资产路径是符号链接：$target_path"
    /bin/cp -f -- "$source_path" "$target_path"
done
[[ -f "$RELEASE_PKG" && -f "$RELEASE_DMG" ]] || fail '无法生成 ASCII 名称的发布资产。'
echo "发布资产：$RELEASE_PKG / $RELEASE_DMG"

# 2) 构建发布工具（与 app 共用同一 scratch 目录，避免额外构建树）
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
[[ -d "$DEVELOPER_DIR" ]] || fail '未找到本机 Command Line Tools。'
SCRATCH="$STAGING/app-build/swift-build"
echo '构建 CoolMacRelease…'
/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --configuration release --arch arm64 --jobs 2 --product CoolMacRelease
BIN_DIR="$(/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --configuration release --arch arm64 --jobs 2 --show-bin-path)"
RELEASE_TOOL="$BIN_DIR/CoolMacRelease"
[[ -x "$RELEASE_TOOL" && ! -L "$RELEASE_TOOL" ]] || fail "未找到发布工具：$RELEASE_TOOL"

# Re-sign with a real identity so the keychain sees a stable program across
# rebuilds. An ad-hoc signature makes the tool's identity its content hash, so
# every rebuild is a new program and the signing key prompts again.
SIGNING_IDENTITY="${COOLMAC_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | /usr/bin/head -1)"
fi
if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
        --identifier 'local.hx10.coolmac.release' "$RELEASE_TOOL" >/dev/null \
        || fail "用 '$SIGNING_IDENTITY' 签名发布工具失败。"
    /usr/bin/codesign --verify --strict "$RELEASE_TOOL" || fail '发布工具签名校验失败。'
    echo "发布工具已用 '$SIGNING_IDENTITY' 签名（钥匙串授权可长期复用）。"
else
    echo '警告：未找到 Apple Development 身份，发布工具仍是 ad-hoc 签名；' >&2
    echo '      每次重新构建后，读取更新私钥都会再次弹出钥匙串授权。' >&2
fi

# 3) 签名清单（私钥只在登录钥匙串；本脚本不接触私钥）
OUT="$DIST/update.json"
[[ ! -L "$OUT" ]] || fail "输出路径是符号链接：$OUT"
if [[ -n "$URL_ARG" ]]; then
    "$RELEASE_TOOL" sign --pkg "$RELEASE_PKG" --version "$VERSION_ARG" --build "$BUILD_ARG" \
        --notes "$NOTES_ARG" --out "$OUT" --url "$URL_ARG"
else
    "$RELEASE_TOOL" sign --pkg "$RELEASE_PKG" --version "$VERSION_ARG" --build "$BUILD_ARG" \
        --notes "$NOTES_ARG" --out "$OUT"
fi
[[ -f "$OUT" && ! -L "$OUT" ]] || fail "签名未生成 update.json：$OUT"
echo "清单：$OUT"
/usr/bin/shasum -a 256 "$OUT"

# 4) 确认后上传：只有这三个文件，绝不上传目录或其他产物
for artifact in "$RELEASE_PKG" "$RELEASE_DMG" "$OUT"; do
    [[ -f "$artifact" && ! -L "$artifact" ]] || fail "不是普通文件，拒绝上传：$artifact"
    case "$artifact" in
        "$DIST/identity.plist"|"$DIST/diagnose.json") fail "拒绝上传非发布产物：$artifact" ;;
    esac
done
echo
echo "即将在 github.com/zzusec/cool-mac 创建 Release v$VERSION_ARG 并上传："
echo "  1) $RELEASE_PKG"
echo "  2) $RELEASE_DMG"
echo "  3) $OUT"
echo '本脚本不执行 git 操作；请自行确认对应源码已提交并推送。'
if [[ "$CONFIRM" -eq 0 ]]; then
    echo '确认上传？输入 yes 继续（其他输入取消）：'
    REPLY_TEXT=''
    read -r REPLY_TEXT || REPLY_TEXT=''
    [[ "$REPLY_TEXT" == 'yes' ]] || fail '未确认，已取消；未上传任何文件。'
fi

# 5) 上传（工具内部再次核对版本、摘要与文件名，并要求 --yes）
"$RELEASE_TOOL" publish --version "$VERSION_ARG" --pkg "$RELEASE_PKG" --dmg "$RELEASE_DMG" --manifest "$OUT" --yes
echo "发布完成：v${VERSION_ARG}。本机未安装、未启动任何东西。"
