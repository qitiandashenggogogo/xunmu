# 应用更新（Sparkle 2）

本文件说明当前接入的真实状态、配置方法与两版本验收步骤。

## 当前状态（未完成，不得对外声称自动更新可用）

已经做完的：

- `Sources/SearchUI/AppUpdateController.swift`：基于 Sparkle 2 的 `SPUStandardUpdaterController`，
  提供「检查更新…」「自动查更新」菜单、后台检查、安装前保存会话。
- `Sources/SearchUI/UpdateFeedConfiguration.swift`：从 Info.plist 读取 `SUFeedURL` /
  `SUPublicEDKey` / `SUAllowsAutomaticUpdates`，缺配置时明确禁用并给出中文原因（纯逻辑，有单测）。
- `Scripts/build-app.sh`：版本参数化（`MACEVERYTHING_SHORT_VERSION` / `MACEVERYTHING_BUNDLE_VERSION`）、
  写入更新元数据、嵌入 `Sparkle.framework`、补 `@executable_path/../Frameworks` rpath、
  先签嵌套 framework 再签应用。
- `Scripts/make-release.sh`：本地生成 zip + appcast，**不上传、不生成密钥**。

还没有的（缺这些就不能完成一次真实网络升级）：

1. **没有更新源地址**（appcast 的 HTTPS 地址）。
2. **没有 Ed25519 更新密钥对**，仓库里也不应出现私钥。
3. **尚未托管更新包和 appcast**。公开源码仓库已有，仍需配置实际更新发布。
4. **没有做过一次真实的旧版 → 新版升级测试**。

在上述四项补齐之前，界面上的「检查更新…」是禁用状态，点了会说明原因，不会静默失败，
也不会退回到任何自制的下载或执行逻辑。

## 版本 pin（已核实）

`Package.swift` 目前 pin：

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
```

2026-10-10 实际查询证据：

```
$ git ls-remote --tags --refs https://github.com/sparkle-project/Sparkle | grep -E 'refs/tags/2\.'
...
2.9.6            ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a
2.10.0           eef1a539a373c1f1a320624b1130fc5de7b2e100
2.10.0-beta.1    39c97c96e6cd0e494068ae6d007ec7bf00b74f8b
```

2.10.0 是当时最新的**正式** tag（唯一更新的 beta 是 2.10.0-beta.1，不是正式版）。同时核对了
tag 2.10.0 的 `Package.swift`：product 名 `Sparkle`，binaryTarget URL 为
`https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip`，
平台 `macOS(.v12)`（本项目要求 14，满足）。

**这是版本 pin，不是验收。** 已验证的只有「能解析、能编译、能打包签名」；
两版本真实升级测试仍未做过。复核命令：

```sh
git ls-remote --tags --refs https://github.com/sparkle-project/Sparkle | grep -E 'refs/tags/2\.'
```

## Sparkle 2.10.0 的 API 注意事项（均按真实头文件修正）

依据：本机缓存的 `SPUUpdater-2.10.0.h`、`SPUUpdaterDelegate-2.10.0.h`，以及
`~/Library/Caches/MacEverything/TestBuild/.../Sparkle.framework/Versions/B/Headers/`。

- 安装前的真正回调是 `func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem)`。
  之前写的 `updaterWillInstallUpdate(_:metadata:)` **不是协议回调**，永远不会被调用，
  等于“安装前保存会话”从来没生效过。已改正。
- `SPUUpdater` 上**没有** `setEdDSAPublicKey`；公钥只能从 Info.plist 的 `SUPublicEDKey` 读。
- `SPUUpdater.setFeedURL(_:)` 在 2.10 已废弃；feed 也走 Info.plist 的 `SUFeedURL`。
- `SPUStandardUpdaterController` 只是容器，属性在 `controller.updater` 上。
- Swift 侧 `startUpdater:` 已导入为 `start()`（`try updater.start()`）。
- `updaterDidNotFindUpdate(_:error:)` 的 error 是**非可选** `any Error`。
- 用户取消的错误码来自 `SUErrors.h`：`SUSparkleErrorDomain` + `SUInstallationCanceledError = 4007`。
  代码里用 `SUSparkleErrorDomain` 与显式常量 4007，不猜 Swift 导入后的枚举前缀。
- Swift 6 下 Sparkle 的委托协议不是 main-actor 隔离的，而本类是 `@MainActor`：
  用 `@preconcurrency SPUUpdaterDelegate` 桥接 + 每个回调标 `nonisolated`，
  再用 `MainActor.assumeIsolated` / `Task { @MainActor in }` 回到主线程。

## 不覆盖用户偏好（重要）

`SPUUpdater.automaticallyChecksForUpdates` 会**持久化到宿主 bundle 的 user defaults**，
头文件明确写着“不要每次启动都赋值，否则会忽略用户的偏好”。因此：

- 构造用 `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate:userDriverDelegate:)`；
- 之后在 `start()` 里显式 `try updater.start()`，不在构造期触发任何检查；
- **只有用户自己切换菜单时**才写这个属性；
- 未配置时不构造控制器、不联网；
- 菜单可用性跟随 `SPUUpdater.canCheckForUpdates`，并在 `AppController.validateMenuItem`
  里返回它 —— AppKit 的自动验证不会把禁用项重新启用。
- `SUAllowsAutomaticUpdates`（允许自动下载）与 `SUEnableAutomaticChecks`（跳过许可询问）
  在 `UpdateFeedConfiguration` 里是两个独立字段；脚本默认**不写**后者，
  以保留 Sparkle 在第二次启动时询问用户的许可机制。

## 公钥校验

`SUPublicEDKey` 必须是 32 字节 Ed25519 公钥的 Base64（44 字符）。
`UpdateFeedReader.isValidPublicEDKey` 与构建脚本都会校验；
不合法则直接禁用更新，不存在“用一个验不了的 key 去接受更新”的路径。

## generate_appcast 2.10.0 的真实参数（之前写错了）

来自官方 `generate-appcast-2.10.0.swift`：

```
generate_appcast [options] <archives-source-dir>     # 位置参数是**目录**，不是 zip 路径
  --ed-key-file <path>     # Ed25519 私钥文件（'-' 读标准输入）
  --account <name>         # 钥匙串账号名，默认 ed25519
  -o <path>                # appcast 输出路径
  --download-url-prefix <url>
```

**不存在** `--ed-private-key` / `--output` / `--changelog`。已全部改正。
另：`--download-url-prefix`（下载地址）与 appcast 自身的托管地址是两件事，脚本里分开设置。

## 历史实测（2026-10-10，以下编译阻断已修复）

- `swift build --target SearchUI --scratch-path ~/Library/Caches/MacEverything/TestBuild`
  → **Build of target: 'SearchUI' complete**（主控先前报的 ConformanceIsolation 错误已消失）。
- `swift build --product MacEverything --scratch-path .build/main` → complete。
  （`swift build` 整体目前会被另一个 worker 正在改的 `Sources/SearchBench/IndexPerfMode.swift`
  编译错误阻断，与本次改动无关：`type 'SearchBenchRunner' has no member 'writeReport`，
  该方法实际定义在 `BenchOptions` 上。）
- `MACEVERYTHING_SIGNING_IDENTITY='Godox Dev' … bash Scripts/build-app.sh`：
  - 打印「Sparkle.framework 上游签名仍然有效，保留原签名」（不再盲签上游组件）；
  - `codesign --verify --deep --strict` 对 app 通过；
  - 逐个独立复验：`Sparkle.framework` / `Updater.app` / `Downloader.xpc` / `Installer.xpc` 全部 OK；
  - 签名身份仍是 `Godox Dev`（`TeamIdentifier=not set`），未公证。
- `bash Scripts/make-release.sh`（用 stub 记录 argv）：实际下发的参数是
  `--ed-key-file <path> -o <appcast> --download-url-prefix <https> <archives目录>`，与官方 2.10.0 一致；
  产物为 `dist/release/{速寻-0.1.0-1.zip, appcast.xml, archives-0.1.0-1/}`。
  **这只证明参数形状正确，不证明签名有效** —— stub 不做真实签名。
- 构建前校验实测生效：feed/key 必须成对、非 HTTPS 被拒、公钥非 32 字节 Base64 被拒、
  版本号含非法字符被拒；`make-release.sh` 对已存在的归档与 appcast **拒绝覆盖**。

## 当时的验证缺口（现已补齐本地测试）

- 2026-10-10 完整测试套件**未能运行**（被上述 SearchBench 编译错误阻断）。新增的
  「发布决策」与「更新配置」测试目标可编译（`swift build --target SearchUITests` 通过），
  但**没有执行结果**，请在该错误修复后重跑 `bash Scripts/test.sh`。

## 打开更新（默认关闭）

`Sources/MacEverything/MacEverythingApp.swift` 在应用启动时插入更新菜单，
`AppController.startUpdates()` 负责触发。配置缺失时不会构造 Sparkle 控制器，
因此在没有更新源的构建里不会有任何网络请求。

## 打包一个可发布的更新包

### 1. 用指定身份构建

```sh
MACEVERYTHING_SIGNING_IDENTITY='Godox Dev' \
MACEVERYTHING_SIGNING_KEYCHAIN="$HOME/Library/Keychains/godox-dev.keychain-db" \
MACEVERYTHING_SHORT_VERSION=0.2.0 \
MACEVERYTHING_BUNDLE_VERSION=2 \
bash Scripts/build-app.sh
```

签名身份与钥匙串沿用 `docs/SIGNING.md` 里已经在用的那套，本脚本不创建证书、
不改钥匙串信任、不导出私钥，也不执行 Apple 公证。

### 2. 配置更新源后再构建一次（同一版本号）

```sh
MACEVERYTHING_SIGNING_IDENTITY='Godox Dev' \
MACEVERYTHING_SIGNING_KEYCHAIN="$HOME/Library/Keychains/godox-dev.keychain-db" \
MACEVERYTHING_SHORT_VERSION=0.2.0 \
MACEVERYTHING_BUNDLE_VERSION=2 \
MACEVERYTHING_FEED_URL='https://<owner>.github.io/<repo>/appcast.xml' \
MACEVERYTHING_PUBLIC_ED_KEY='<Ed25519 公钥的 44 字符 Base64>' \
MACEVERYTHING_ALLOW_AUTOMATIC_DOWNLOADS=YES \
bash Scripts/build-app.sh
```

`MACEVERYTHING_FEED_URL` 与 `MACEVERYTHING_PUBLIC_ED_KEY` 必须同时给，只给一个会以退出码 2 拒绝；
公钥不是 32 字节 Base64、feed 不是 HTTPS、版本号含非法字符同样在编译前就退出。
`MACEVERYTHING_ALLOW_AUTOMATIC_DOWNLOADS=YES` 只写 `SUAllowsAutomaticUpdates`（允许自动下载），
**不会**写 `SUEnableAutomaticChecks`，因此 Sparkle 仍会在第二次启动时询问用户是否允许自动检查。

### 3. 生成 zip 与 appcast（本地，不上传）

```sh
MACEVERYTHING_ED_PRIVATE_KEY="$HOME/.config/maceverything/update_ed25519" \
MACEVERYTHING_FEED_URL='https://<owner>.github.io/<repo>/appcast.xml' \
MACEVERYTHING_DOWNLOAD_URL_PREFIX='https://github.com/<owner>/<repo>/releases/download/' \
MACEVERYTHING_GENERATE_APPCAST='/path/to/generate_appcast' \
bash Scripts/make-release.sh
```

版本号从已构建 app 的 `Info.plist` 读取，不依赖环境变量猜测。
脚本会先把 zip 放进一个只含本次归档的目录，再把它作为 `generate_appcast` 的位置参数。
已存在的归档或 appcast 会被**拒绝覆盖**（退出码 2），需要手工归档旧文件。

### generate_appcast 不在 SwiftPM 包里

Sparkle 的 SPM 二进制发行包只包含框架，不包含 `generate_appcast`。
脚本在找不到该工具时以退出码 3 中止，并要求用 `MACEVERYTHING_GENERATE_APPCAST`
指向本机已有的 Sparkle 官方发行工具。**不会伪造 appcast。**

## 两版本真实升级测试步骤

需要两台机器或两个独立副本（一个当「旧版」，一个当「新版」），以及一个真实的 HTTPS
appcast 托管位置。

1. 用版本 `0.1.0`（`MACEVERYTHING_BUNDLE_VERSION=1`）构建并安装到测试机 A，
   确认配置了同一个 feed 与公钥，启动后菜单里「检查更新…」可用。
2. 在 A 上建立一点索引、跑一次搜索、选中某一行、滚动到中部，然后退出（会保存会话）。
3. 用版本 `0.2.0`（`MACEVERYTHING_BUNDLE_VERSION=2`）重新构建，走 `make-release.sh` 生成
   zip 与 appcast，由人工上传到 Releases + 固定 appcast 地址。
4. 重新打开 A（旧版），执行「检查更新…」，走完下载、校验、替换、重启的完整流程。
5. 验收清单：
   - 更新包下载成功且**签名校验通过**（appcast 的 EdDSA 公钥与旧版内嵌公钥一致）。
   - 更新后版本号确实变成 `0.2.0`。
   - **索引、查询历史、选中行、滚动位置仍在**（退出安装前会保存会话，索引不删除）。
   - 卷的在线/待校验状态显示正常。
   - 离线卷的文件仍可搜索、仍不能打开，提示清楚。
6. 失败时记录 Sparkle 给出的错误码与用户驱动界面截图，再改代码；不要用「重装一次就好了」
   代替定位。

## 信任边界（必须如实提示用户）

当前构建是本地自签名（`Godox Dev`）且**未公证**。因此：

- 同事首次从浏览器下载后，macOS 仍可能提示无法验证，需要在
  「系统设置 → 隐私与安全性」里点「仍要打开」。这是既有自签名路线的固有边界，
  自动更新不会消除它。
- 未公证的包**不得**被称为「正式公证包」，文档、发布说明与提交信息里都不要这么写。
- 自动更新的安全性来自 Sparkle 的 Ed25519 包签名与 HTTPS feed，不来自 Apple 公证；
  两者是独立的，不要混为一谈。

## 不做的事

- 不自制下载器或安装执行器（全部交给 Sparkle）。
- 不生成、不导出、不传输更新私钥；私钥必须留在使用者自己的机器上，且不进仓库。
- 不改 Library Validation 或任何全局安全策略。
- 不在缺更新源/公钥/仓库时伪造「自动更新已通」。

## 寻目品牌版本地验收（2026-10-12）

主控完整运行 429 项 Swift Testing 测试、49 个套件通过，2 项真实外置盘用例跳过。
更新配置用例实际运行通过；未配置更新源时，真实 AppKit 菜单自动校验后仍禁用更新检查。
应用改名为寻目，Bundle ID、可执行文件与本地数据目录延续 MacEverything。
这不代表已经完成两版本网络升级；更新源、Ed25519 更新密钥和实际升级验收仍待补齐。
