#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Build outside File Provider / iCloud Documents, which may reattach
# FinderInfo after signing or evict mmap-backed compiler cache files.
artifact_root="${MACEVERYTHING_BUILD_DIR:-$HOME/Library/Caches/MacEverything/Build}"
scratch_dir="${MACEVERYTHING_SCRATCH_DIR:-$artifact_root/SwiftBuild}"
# A local certificate can give successive builds a stable signing identity.
# It does not provide Developer ID trust or Apple notarization.
signing_identity="${MACEVERYTHING_SIGNING_IDENTITY--}"
signing_keychain="${MACEVERYTHING_SIGNING_KEYCHAIN:-}"
if [[ -z "$signing_identity" ]]; then
    printf '签名身份不能为空；本地临时签名请指定 -。\n' >&2
    exit 2
fi

# Version identity. Feed metadata must match Info.plist exactly, otherwise
# Sparkle cannot tell whether the installed build is older than the feed.
# 展示名（寻目）只影响包名与菜单显示；Bundle ID、可执行文件与数据目录仍沿用 MacEverything。
app_name="${MACEVERYTHING_APP_NAME:-寻目}"
bundle_id="${MACEVERYTHING_BUNDLE_ID:-local.maceverything.search}"
short_version="${MACEVERYTHING_SHORT_VERSION:-0.1.0}"
bundle_version="${MACEVERYTHING_BUNDLE_VERSION:-1}"
# Update feed / public key. Empty means "updates disabled", which is the default.
feed_url="${MACEVERYTHING_FEED_URL:-}"
public_ed_key="${MACEVERYTHING_PUBLIC_ED_KEY:-}"
# SUAllowsAutomaticUpdates: whether the updater may download in the background.
# This is NOT the same as SUEnableAutomaticChecks (skipping the permission prompt);
# we deliberately leave SUEnableAutomaticChecks out so Sparkle can ask the user.
allow_automatic_downloads="${MACEVERYTHING_ALLOW_AUTOMATIC_DOWNLOADS:-NO}"

# ---- Validate configuration BEFORE spending a release build on it ----
validate_version() {
  local value="$1" label="$2"
  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    printf '%s 不合法：%s（只接受数字与点，例如 0.2.0）\n' "$label" "$value" >&2
    exit 2
  fi
}
validate_version "$short_version" "MACEVERYTHING_SHORT_VERSION"
if [[ ! "$bundle_version" =~ ^[0-9]+$ ]]; then
  printf 'MACEVERYTHING_BUNDLE_VERSION 不合法：%s（必须是整数）\n' "$bundle_version" >&2
  exit 2
fi

if [[ -n "$feed_url" || -n "$public_ed_key" ]]; then
  if [[ -z "$feed_url" || -z "$public_ed_key" ]]; then
    printf '更新配置不完整：MACEVERYTHING_FEED_URL 与 MACEVERYTHING_PUBLIC_ED_KEY 必须同时提供。\n' >&2
    exit 2
  fi
  case "$feed_url" in
    https://*) ;;
    *) printf '更新源必须使用 HTTPS：%s\n' "$feed_url" >&2; exit 2 ;;
  esac
  # Ed25519 public key must be 32 bytes of Base64.
  if [[ ${#public_ed_key} -ne 44 ]] || ! printf '%s' "$public_ed_key" | base64 -d 2>/dev/null | wc -c | grep -qx 32; then
    printf '更新公钥不合法：SUPublicEDKey 必须是 32 字节 Ed25519 公钥的 Base64（44 字符）。\n' >&2
    exit 2
  fi
  printf '自动更新配置已校验（feed=%s）。本脚本不上传任何内容。\n' "$feed_url"
else
  printf '未配置更新源，自动更新保持禁用。\n'
fi

# App icon: a stable release resource, independent of docs/branding proposals.
app_icon="$project_dir/Resources/AppIcon.icns"
if [[ ! -s "$app_icon" ]]; then
  printf '缺少应用图标或文件为空：%s（发布图标应放在 Resources/AppIcon.icns）\n' "$app_icon" >&2
  exit 2
fi
if [[ "$(head -c 4 "$app_icon")" != "icns" ]]; then
  printf '应用图标不是有效的 .icns 文件：%s\n' "$app_icon" >&2
  exit 2
fi

# Materialize our source inputs before Swift records their timestamps.
python3 - <<'PYINPUTS'
from pathlib import Path
Path('Package.swift').read_bytes()
for path in Path('Sources').rglob('*'):
    if path.is_file():
        path.read_bytes()
PYINPUTS
swift build -c release --product MacEverything --scratch-path "$scratch_dir"
binary_dir="$(swift build -c release --show-bin-path --scratch-path "$scratch_dir")"

app_dir="$artifact_root/$app_name.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$binary_dir/MacEverything" "$app_dir/Contents/MacOS/MacEverything"
# Copied before signing so the app seal covers it.
cp "$app_icon" "$app_dir/Contents/Resources/AppIcon.icns"

# Info.plist is generated with plistlib so &, <, > and non-ASCII values are
# escaped correctly; hand-written heredoc XML breaks on those characters.
python3 - "$app_dir/Contents/Info.plist" <<'PYPLIST'
import plistlib, sys
from pathlib import Path

path = Path(sys.argv[1])
info = {
    "CFBundleExecutable": "MacEverything",
    "CFBundleIconFile": "AppIcon",
    "CFBundleIdentifier": "local.maceverything.search",
    "CFBundleName": "寻目",
    "CFBundleDisplayName": "寻目",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSRemovableVolumesUsageDescription": "读取您选定的外置卷文件名，建立本机搜索索引。",
    "NSDocumentsFolderUsageDescription": "读取您选定的文件夹名称与文件元数据，用于快速搜索。",
    "NSDownloadsFolderUsageDescription": "读取您选定的下载目录文件名，用于快速搜索。",
    "NSDesktopFolderUsageDescription": "读取您选定的桌面文件名，用于快速搜索。",
}

import os
feed = os.environ.get("MACEVERYTHING_FEED_URL", "").strip()
key = os.environ.get("MACEVERYTHING_PUBLIC_ED_KEY", "").strip()
if feed:
    info["SUFeedURL"] = feed
if key:
    info["SUPublicEDKey"] = key
if os.environ.get("MACEVERYTHING_ALLOW_AUTOMATIC_DOWNLOADS", "NO") == "YES":
    # Allows background downloading. Deliberately NOT SUEnableAutomaticChecks:
    # leaving it out preserves Sparkle's permission prompt on the second launch.
    info["SUAllowsAutomaticUpdates"] = True

# Overridable identity fields (env already validated by the shell wrapper).
info["CFBundleIdentifier"] = os.environ.get("MACEVERYTHING_BUNDLE_ID", info["CFBundleIdentifier"])
info["CFBundleName"] = os.environ.get("MACEVERYTHING_APP_NAME", info["CFBundleName"])
info["CFBundleDisplayName"] = info["CFBundleName"]
info["CFBundleShortVersionString"] = os.environ.get("MACEVERYTHING_SHORT_VERSION", info["CFBundleShortVersionString"])
info["CFBundleVersion"] = os.environ.get("MACEVERYTHING_BUNDLE_VERSION", info["CFBundleVersion"])

path.write_bytes(plistlib.dumps(info, sort_keys=True))
PYPLIST
plutil -lint "$app_dir/Contents/Info.plist"

# Sparkle.framework embedding. SwiftPM links Sparkle from the XCFramework but does
# not copy it into the app bundle, so we embed it ourselves and add the rpath the
# loader needs. ditto preserves symlinks; cp -R would mangle Versions/Current.
sparkle_framework="$(find "$scratch_dir" -type d -name 'Sparkle.framework' -print -quit 2>/dev/null || true)"
if [[ -z "$sparkle_framework" ]]; then
  printf '未在构建目录找到 Sparkle.framework；无法生成可运行的更新包。\n' >&2
  exit 3
fi
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
find "$app_dir/Contents/Frameworks/Sparkle.framework" -name '._*' -delete 2>/dev/null || true

# rpath: Sparkle.framework lives at Contents/Frameworks, the loader starts in Contents/MacOS.
if ! otool -l "$app_dir/Contents/MacOS/MacEverything" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_dir/Contents/MacOS/MacEverything"
fi
if ! otool -L "$app_dir/Contents/MacOS/MacEverything" | grep -q '@rpath/Sparkle.framework'; then
    printf '主二进制未引用 @rpath/Sparkle.framework，Sparkle 可能未链接；请检查依赖是否被裁剪。\n' >&2
    exit 3
fi

# Sign in a staging copy outside any File Provider / iCloud-synced folder.
#
# When the artifact root sits under Documents (this project's own case), macOS
# keeps re-attaching com.apple.fileprovider.* to the nested XPC services, and
# codesign then fails with "resource fork, Finder information, or similar
# detritus not allowed" even right after xattr -c. Staging under TMPDIR makes the
# cleanup stick. Only our own generated bundle is staged.
final_app_dir="$app_dir"
staging_dir="$(mktemp -d)"
cleanup() { rm -rf "$staging_dir"; }
trap cleanup EXIT
staged_app="$staging_dir/$app_name.app"
ditto "$app_dir" "$staged_app"
app_dir="$staged_app"
find "$app_dir" -name '._*' -delete 2>/dev/null || true
xattr -cr "$app_dir" 2>/dev/null || true

signing_args=(--force --sign "$signing_identity" --timestamp=none)
if [[ -n "$signing_keychain" ]]; then
    signing_args+=(--keychain "$signing_keychain")
fi

# Nested code: Sparkle.framework contains Updater.app, XPCServices/*.xpc and the
# standalone Autoupdate tool. Order matters — a bundle seals its nested code, so
# the deepest components must be signed before their containers. `sort -r` gives
# that order by path depth.
framework_dir="$app_dir/Contents/Frameworks/Sparkle.framework"
if codesign --verify --deep --strict "$framework_dir" 2>/dev/null; then
    # Prefer the upstream signature when it is already valid: re-signing a
    # Developer ID component with our local identity only weakens it.
    printf 'Sparkle.framework 上游签名仍然有效，保留原签名。\n'
else
    printf 'Sparkle.framework 上游签名无效或缺失，按内层到外层重新签名。\n'
    # 签名顺序：先独立 Mach-O 工具 → 再 XPC / app 容器 → 最后 framework。
    # framework 自己的主二进制（CFBundleExecutable 指向的那个）绝不能当成
    # 「独立工具」单独签 —— framework 签名之后再去改它，会让 framework 签名失效。
    framework_binary_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$framework_dir/Versions/B/Resources/Info.plist" 2>/dev/null || echo 'Sparkle')"
    while IFS= read -r nested; do
        find "$nested" -name '._*' -delete 2>/dev/null || true
        xattr -cr "$nested" 2>/dev/null || true
        codesign "${signing_args[@]}" "$nested"
    done < <(find "$framework_dir/Versions/B" -maxdepth 1 -type f -perm -111 ! -name "$framework_binary_name" 2>/dev/null | sort -r)
    while IFS= read -r nested; do
        find "$nested" -name '._*' -delete 2>/dev/null || true
        xattr -cr "$nested" 2>/dev/null || true
        codesign "${signing_args[@]}" "$nested"
    done < <(find "$framework_dir" \( -name '*.app' -o -name '*.xpc' \) -type d 2>/dev/null | sort -r)
    # framework 必须最后签：它会封存自己的嵌套代码。
    find "$framework_dir" -name '._*' -delete 2>/dev/null || true
    xattr -cr "$framework_dir" 2>/dev/null || true
    codesign "${signing_args[@]}" "$framework_dir"
fi

# Third-party notices: ship Sparkle's own LICENSE verbatim from the resolved
# distribution (not retyped, and no GPL text copied in).
notices_dir="$app_dir/Contents/Resources/ThirdPartyNotices"
mkdir -p "$notices_dir"
sparkle_license="$(find "$scratch_dir" -maxdepth 6 -type f -name LICENSE -path '*parkle*' -print -quit 2>/dev/null || true)"
if [[ -n "$sparkle_license" ]]; then
    cp "$sparkle_license" "$notices_dir/Sparkle-LICENSE"
    printf '第三方许可：已随包保留 Sparkle 许可证。\n'
else
    printf '警告：未找到 Sparkle 的 LICENSE 文件，未能随包保留第三方许可。\n' >&2
fi

find "$app_dir" -name '._*' -delete 2>/dev/null || true
xattr -cr "$app_dir" 2>/dev/null || true
codesign "${signing_args[@]}" "$app_dir"

# Verify deeply: the app seal alone does not prove nested code is intact.
if ! codesign --verify --deep --strict "$app_dir"; then
    printf '应用包签名校验失败（--deep --strict）。\n' >&2
    exit 6
fi
if [[ "$signing_identity" == "-" ]]; then
    printf '签名模式：本机临时签名，未公证。\n'
else
    printf '签名身份：%s；本脚本未执行 Apple 公证。\n' "$signing_identity"
fi

# Move the signed bundle back to the artifact root.
rm -rf "$final_app_dir"
ditto "$app_dir" "$final_app_dir"
app_dir="$final_app_dir"
# Re-verify where it actually landed. If the artifact root sits inside a File
# Provider / iCloud-synced folder (e.g. the project itself), macOS re-attaches
# com.apple.FinderInfo on write and the freshly signed bundle stops verifying.
if ! codesign --verify --deep --strict "$app_dir" 2>/dev/null; then
    printf '签名校验失败：产物目录 %s 位于 File Provider / iCloud 同步目录内，签名后属性被重新附加。\n' "$final_app_dir" >&2
    printf '请把产物放到同步目录之外（默认即为 ~/Library/Caches/MacEverything/Build），或用 MACEVERYTHING_BUILD_DIR 指定。\n' >&2
    exit 5
fi

mkdir -p "$project_dir/dist"
python3 - "$project_dir/dist/$app_name.app" "$app_dir" <<'PYLINK'
from pathlib import Path
import shutil, sys
link, artifact = map(Path, sys.argv[1:])
if link.is_symlink():
    link.unlink()
elif link.exists():
    # Only replace our previous generated bundle; refuse unrelated destinations.
    if not (link / "Contents/MacOS/MacEverything").is_file():
        raise SystemExit("构建链接目标被其他文件占用：" + str(link))
    shutil.rmtree(link)
link.symlink_to(artifact, target_is_directory=True)
PYLINK
printf '版本：%s (%s)\n本地应用：%s\n项目启动链接：%s\n' "$short_version" "$bundle_version" "$app_dir" "$project_dir/dist/$app_name.app"
