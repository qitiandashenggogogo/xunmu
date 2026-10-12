#!/bin/bash
# 准备（不上传）一个可发布到 GitHub Releases 的更新包与 appcast。
#
# generate_appcast 2.10.0 的真实命令行（来自官方 generate-appcast 源码）：
#   generate_appcast [options] <archives-source-dir>
#     --ed-key-file <path>   Ed25519 私钥文件（'-' 表示从标准输入读）
#     --account <name>       从钥匙串读取的账号名（默认 ed25519）
#     -o <path>             生成的 appcast 输出路径
#     --download-url-prefix <url>
#   注意：没有 --ed-private-key / --output / --changelog 这三个参数。
#
# 本脚本只做本地打包与签名：
#   1. ditto 打 zip（保留 symlink 与权限）。
#   2. 把 zip 放进一个只含本次归档的目录，作为 archives 源目录。
#   3. 调 generate_appcast 生成并用 Ed25519 私钥签名 appcast.xml。
#
# 明确不做的事：
#   - 不上传、不推送、不创建仓库、不发布 release。
#   - 不生成、不导出、不传输更新私钥；私钥必须由使用者单独保管。
#   - 不执行 Apple 公证；未公证的包不得被称为「正式公证包」。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

artifact_root="${MACEVERYTHING_BUILD_DIR:-$HOME/Library/Caches/MacEverything/Build}"
app_name="${MACEVERYTHING_APP_NAME:-寻目}"
app_dir="$artifact_root/$app_name.app"
out_dir="$project_dir/dist/release"
# The Ed25519 private key stays outside the repo. We only read it through
# generate_appcast and never copy it.
private_key="${MACEVERYTHING_ED_PRIVATE_KEY:-}"
generate_appcast="${MACEVERYTHING_GENERATE_APPCAST:-generate_appcast}"
# Where the app will be downloaded from. Kept separate from the appcast URL:
# the feed describes the update, --download-url-prefix describes the payload.
download_url_prefix="${MACEVERYTHING_DOWNLOAD_URL_PREFIX:-}"
feed_url="${MACEVERYTHING_FEED_URL:-}"

if [[ ! -d "$app_dir" ]]; then
    printf '找不到已构建的应用：%s\n先运行 Scripts/build-app.sh。\n' "$app_dir" >&2
    exit 2
fi
if [[ -z "$private_key" ]]; then
    printf '未提供更新私钥：设置 MACEVERYTHING_ED_PRIVATE_KEY 指向本地 Ed25519 私钥文件。\n' >&2
    printf '本脚本不会生成或导出私钥；没有私钥就无法产出可校验的 appcast。\n' >&2
    exit 2
fi
if [[ ! -f "$private_key" ]]; then
    printf '更新私钥文件不存在：%s\n' "$private_key" >&2
    exit 2
fi
if ! command -v "$generate_appcast" >/dev/null 2>&1; then
    printf '找不到 generate_appcast（Sparkle 官方发行工具）。\n' >&2
    printf '设置 MACEVERYTHING_GENERATE_APPCAST 指向本机已有的 generate_appcast 可执行文件。\n' >&2
    printf 'Sparkle 的 SPM 二进制包不包含该工具，因此这里不会伪造 appcast。\n' >&2
    exit 3
fi

# Version identity comes from the built bundle, not from an env guess: the
# appcast and Info.plist must describe the exact same build.
read_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$app_dir/Contents/Info.plist" 2>/dev/null || true
}
short_version="$(read_plist_value CFBundleShortVersionString)"
bundle_version="$(read_plist_value CFBundleVersion)"
if [[ -z "$short_version" || -z "$bundle_version" ]]; then
    printf '无法从 %s 读取版本号，请先构建。\n' "$app_dir/Contents/Info.plist" >&2
    exit 2
fi

archive_name="$app_name-$short_version-$bundle_version.zip"
archive_path="$out_dir/$archive_name"
if [[ -e "$archive_path" ]]; then
    printf '目标文件已存在，拒绝覆盖：%s\n' "$archive_path" >&2
    printf '请先手工移走，或改用新的版本号重新构建。\n' >&2
    exit 2
fi
if [[ -e "$out_dir/appcast.xml" ]]; then
    printf '已存在 appcast.xml（%s），拒绝覆盖。\n' "$out_dir/appcast.xml" >&2
    printf '请先手工归档旧 appcast 后重试。\n' >&2
    exit 2
fi

mkdir -p "$out_dir"
# generate_appcast takes a *directory* of archives, so stage just this one build.
archives_dir="$out_dir/archives-$short_version-$bundle_version"
if [[ -e "$archives_dir" ]]; then
    printf '暂存目录已存在，拒绝覆盖：%s\n' "$archives_dir" >&2
    exit 2
fi
mkdir -p "$archives_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archives_dir/$archive_name"

appcast_path="$out_dir/appcast.xml"
generate_args=(--ed-key-file "$private_key" -o "$appcast_path")
if [[ -n "$download_url_prefix" ]]; then
    case "$download_url_prefix" in
        https://*) ;;
        *) printf '下载地址前缀必须使用 HTTPS：%s\n' "$download_url_prefix" >&2; exit 2 ;;
    esac
    generate_args+=(--download-url-prefix "$download_url_prefix")
fi

# Writes appcast.xml to the given path; never uploads anything.
"$generate_appcast" "${generate_args[@]}" "$archives_dir"

if [[ ! -f "$appcast_path" ]]; then
    printf 'generate_appcast 未产出 appcast.xml，中止。\n' >&2
    exit 4
fi
# The archive lives inside the staging dir so the feed is generated from a clean
# single-archive directory; copy it out for the manual upload step.
cp "$archives_dir/$archive_name" "$out_dir/$archive_name"

if [[ -z "$feed_url" ]]; then
    printf '未设置 MACEVERYTHING_FEED_URL：appcast 的托管地址需要人工确认。\n' >&2
fi
if [[ -z "$download_url_prefix" ]]; then
    printf '未设置 MACEVERYTHING_DOWNLOAD_URL_PREFIX：appcast 中的下载地址需要人工替换成 HTTPS。\n' >&2
fi

printf '\n已生成（未上传）：\n  更新包：%s\n  appcast：%s\n  归档源目录：%s\n' "$out_dir/$archive_name" "$appcast_path" "$archives_dir"
printf '\n人工上传步骤（本脚本不做）：\n'
printf '  1. 把 %s 上传到该仓库的 GitHub Releases（tag 建议 v%s）。\n' "$archive_name" "$short_version"
printf '  2. 把 appcast.xml 放到固定 HTTPS 地址，例如 https://<owner>.github.io/<repo>/appcast.xml。\n'
printf '  3. 确认 appcast.xml 里 <enclosure url> 指向该 Releases 的 HTTPS 下载地址。\n'
printf '  4. 用同一把 Ed25519 公钥重建应用：MACEVERYTHING_PUBLIC_ED_KEY=<公钥> bash Scripts/build-app.sh\n'
printf '  5. 旧版执行「检查更新…」完成一次真实升级，并确认索引与会话状态未被删除。\n'
printf '\n注意：当前为本地自签名且未公证，首次打开仍受 Gatekeeper 信任边界影响。\n'
