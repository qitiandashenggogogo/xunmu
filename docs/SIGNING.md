# 本地证书签名与同事安装

用户于 2026-10-10 选择沿用“引闪器桌面端”的本地证书签名方式，当前没有 Apple Developer Program 付费账号。

这条路线不执行 Apple 公证，也不把自签名伪装成 Developer ID 签名。签名可以验证应用包完整性，并为连续版本提供固定签名身份；同事通过浏览器下载后，macOS 仍可能阻止首次打开。

## 构建

脚本默认仍使用临时签名，适用于没有本地证书的开源贡献者。使用已有的本地代码签名证书时：

```sh
MACEVERYTHING_SIGNING_IDENTITY='Godox Dev' \
MACEVERYTHING_SIGNING_KEYCHAIN="$HOME/Library/Keychains/godox-dev.keychain-db" \
bash Scripts/build-app.sh
```

证书名称和钥匙串位置取自当前开发机；其他开发者使用自己的签名身份即可。脚本不创建证书、不改钥匙串信任、不解锁钥匙串、不导出私钥。签名失败会终止构建，不静默回退到临时签名。`--timestamp=none` 是当前本地证书路线，不适用于将来需要安全时间戳的正式公证流程。

## 同事首次安装

将应用复制到“应用程序”，尝试打开。如果系统提示开发者无法验证，同事可以在“系统设置 → 隐私与安全性”中为这个应用选择“仍要打开”。不要求关闭 Gatekeeper、SIP 或降低系统安全策略，也不要求安装或信任开发者的自签名根证书。

完全磁盘访问权限由同事按需要单独授予。当前应用从临时签名切换到证书签名后，原有隐私授权是否保留需要实测；失效时重新授权应用，不修改系统权限数据库。

## 自动更新

自动更新另用 Sparkle 的 Ed25519 更新包签名与 HTTPS 验证来源，公开仓库只保存更新公钥。更新私钥必须单独保管，不能放进源码、应用、诊断包或 GitHub Release。

自签名不能替代首次安装的 Gatekeeper 信任；自动更新是否在目标系统上顺利安装，需要真实旧版到新版测试。当前已接入 Sparkle 2.10.0，但尚未配置更新密钥和发布更新源，缺少配置时更新检查保持禁用；不能宣称自动更新已经可用。

## 已实际验证

2026-10-10：复用已有 `Godox Dev` 身份对速寻副本签名成功；`codesign --verify --strict --verbose=2` 通过，签名显示 `Authority=Godox Dev`、`TeamIdentifier=not set`。未修改系统信任、导出私钥或公证。该证书元数据的到期时间为 2036-09-20；证书及私钥仍留在已有钥匙串中。

随后通过带签名参数的完整构建脚本生成当时的 `dist/速寻.app`，再次严格验签通过。空签名身份实测以退出码 2 拒绝执行，不会静默替换为临时签名。

本机 `spctl --assess` 返回 `accepted`，但同时明确显示 `override=security disabled`：本机原有 Gatekeeper 配置未启用，不能据此声称证书受到 Apple 信任或同事电脑会无提示放行。本次没有改变该配置。

同事另一台 Mac 的浏览器下载首次安装、两版本自动更新和隐私授权保留尚未验收。当前构建产物仅为 Apple Silicon arm64，Intel 构建需要另行支持。

参考：[Apple 的首次打开说明](https://support.apple.com/en-gb/102445)、[Sparkle 签名与分发文档](https://sparkle-project.org/documentation/)。

2026-10-12：品牌版 `寻目.app` 使用同一 `Godox Dev` 身份构建；主应用、Sparkle.framework、Updater.app、两个 XPC 及 Autoupdate 严格验签通过，实际 `--smoke` 通过。旧包未删除，首次跨机安装与真实自动升级仍未验收。
