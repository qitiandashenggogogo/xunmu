# 开源准备与发布状态

> 源码仓库：[qitiandashenggogogo/xunmu](https://github.com/qitiandashenggogogo/xunmu)。
> MIT 开源；自动更新、远程崩溃上报与跨机安装验收的状态见下文。
> 更新时间：2026-10-12。

## 1. 许可证

采用标准 MIT 许可证，见 [LICENSE](../LICENSE)。版权行：`Copyright (c) 2026 MacEverything contributors`。
选择 MIT 的原因：允许他人自由使用、修改、再分发与商用（含闭源集成），唯一义务是保留版权与许可声明。

## 2. 第三方许可与官方通知

| 组件 | 用途 | 许可 | 是否随包分发 |
| --- | --- | --- | --- |
| SQLite | 索引持久化 | SQLite 是**公有领域**（public domain），作者声明放弃版权 | 否，通过系统 `libsqlite3` 链接 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0 | 应用内更新检查框架 | **MIT**（Sparkle 项目） | 是，`Sparkle.framework` 随 `.app` 打包 |
| macOS 系统框架（Foundation / AppKit / CoreServices / Darwin） | 应用运行 | Apple 系统框架，随 macOS 提供 | 否，随操作系统 |
| Swift 6 / SwiftPM | 构建 | Apache 2.0（Swift 编译器）；本项目自身代码不使用 Swift 编译器源码 | 否 |

### 2.1 Sparkle 是当前唯一的远程依赖

`Package.swift` 以 `exact: "2.10.0"` 精确锁定 Sparkle，解析结果记录在 `Package.resolved`。
开源发布时必须注意：

- **首次构建需要网络**（拉取 Sparkle）或本地已有缓存；不像纯系统依赖那样开箱即编。
- Sparkle 采用 MIT 许可，与本项目 MIT 兼容；但**保留其版权与许可声明**，
  `Sparkle.framework` 随应用分发时其 `LICENSE` 文件应一并保留。
- 官方通知与许可全文：<https://github.com/sparkle-project/Sparkle>（MIT，见仓库根目录 LICENSE）。
- 若将来移除 Sparkle，`Package.resolved` 与打包脚本里的 framework 嵌入逻辑需同步调整。

**除 Sparkle 外没有其他第三方 Swift 包**；索引与扫描只依赖系统 SQLite 与系统框架。
详细的第三方依赖条款、上游 External Licenses 全文说明、开源理念启发与同类开源参考见 **[docs/ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)**。

## 3. 泄露审计结果（只列问题，未删改任何历史或用户资产）

审计范围：`git ls-files` 跟踪的全部文件、已提交的 git 历史（b13c117 及更早）、
`docs/` 下的文档与截图。审计项：私有路径、卷 UUID、文件名、调度内部标识、凭据。

> **本文自身不写任何具体私有标识。** 下文一律用「本机用户名」「外置卷名」「硬盘型号」等
> 泛称描述检查项与结论。公开审计文档如果把被审计对象的真实标识再写一遍，
> 那审计本身就变成了泄露途径——所以下面找不到任何一个真实用户名、卷名或盘型号。

### 3.1 已确认的**问题**（需处理）

| # | 位置 | 问题 | 严重度 | 建议处理 | 归属 |
| --- | --- | --- | --- | --- | --- |
| 1 | `docs/benchmarks/2026-10-09-100k.json` 第 80、188 行 | **当前源码快照已修复**。原本的 `persistence.databasePath` 与 `scan.fixturePath` 含本机临时目录完整路径，其中中间那串是 macOS 的**每用户哈希目录**，属机器本地标识 | 低（不含用户名，但可关联同一台机器的多次运行） | 已改为 `<temporary-directory>/…` 占位符。**注意：这是对既有报告文件的手工脱敏，不是基准工具产出的结果**——下次重跑该基准会重新写出真实临时路径，需要把脱敏做成工具行为或再加一道导出步骤，否则问题 1 会重新出现 | 已完成；公开快照保留脱敏版 |
| 2 | `Tests/SearchScannerTests/FileEventMonitorTests.swift:221` | 夹具里出现形如 `/Users/<占位>/b` 的字面量 | 无（合成占位符，非真实用户名） | 可保留；若追求整洁可改为非 `/Users` 前缀的占位写法 | 不在本次所有权内 |
| 3 | git 历史 b68bf77 及更早 | 历史提交中仍保留了问题 1 的原始内容 | 低 | **不改写历史**（用户资产）。保留本地历史，公开仓库从已检查的源码快照开始，不上传旧历史 | 主控决策 |

问题 1 修复后的现状：`docs/benchmarks/` 下 5 份公开 JSON（含 2026-10-12 新增的百万条合成报告）
均可正常解析，逐字段遍历后**不含任何绝对本地路径、本机用户名、外置卷名、凭据或会话标识**
（与 `ReleaseCapabilityAcceptanceTests.swift` 里的泄露回归断言一致）。

### 3.2 已确认**干净**的部分

- **本机用户名**：跟踪文件里不出现真实登录名，也不出现以真实用户目录开头的绝对路径。
  **这项检测是运行期做的**：验收用例在运行时取 `NSUserName` / `NSFullUserName`，
  再去扫已发布 JSON。源码里**没有**写死任何用户名常量（那本身就会成为泄露途径）。
- **外置卷名与硬盘型号**：真实盘报告里的卷名、卷 UUID、设备号已脱敏，报告只保留文件系统类型
  （如 `tuxera_ntfs` / `exfat`）、在线状态、安全闸判定结论。
  **卷名/盘型号的检测同样不写死在源码**：若本机还有其它私有卷名或硬件标识，
  由**运行环境**通过 `MACEVERYTHING_PRIVATE_IDENTIFIERS_JSON`（一个字符串数组）注入，
  验收用例在运行期一并检查。这些值属于本机私密配置，**不写入仓库、不记录在本文件中**。
  > 未配置该变量时（CI 常见情形），用例仍然会自动检查**本机用户名**，
  > 以及与具体取值无关的**通用边界**：绝对路径、`/Users/<真实用户>` 形式、凭据特征、路径级字段名。
  > 那种配置下**不声称**“任意私有卷名都已被覆盖”——只覆盖上面这些。
- **用户文件名 / 目录**：跟踪文件里没有真实照片名、合同名、文件名。测试夹具全部是合成名。
- **凭据 / 私钥 / 令牌**：无 PEM/P12 私钥块、无 API key、无 token。
  `Sources/MacEverything/AppController.swift` 里的 `workspaceTokens` 是 NSWorkspace 观察者令牌，与凭据无关。
- **调度内部标识**：`GOAL.md` 与 `docs/VALIDATION.md` 只保留“执行方为 MiniMax M3.1 Flash Preview”
  这一**事实描述**，provider / session / worker 等内部标识已删除。
  （`Tests/` 里出现的 `worker_id` / `session_id` 字样是泄露回归测试的**禁止词表**，不是实际标识。）
- **截图** `docs/app-preview-xunmu-2026-10-12.png`（当前版本）与 `docs/app-preview.png`（旧版，保留作过程记录）：
  两者内容都是**演示夹具**数据（合成文件名、小体积、占位卷名、演示搜索词），不含真实用户文件名或私有路径。
  旧版已知表头与第一行重叠，已在 2026-10-12 修复，新截图经查看确认无重叠。

### 3.3 本次已做的脱敏（仅限本会话拥有的文件）

- 新增 [LICENSE](../LICENSE) 与本文件。
- `.gitignore` 新增：本地诊断产物（`diagnostics/`、`*.ips`、`*.crash`、`*.log`）、
  签名与凭据（`*.p12`、`*.pem`、`*.key`、`*.mobileprovision`、`*.env`、`secrets*.json`）、
  打包中间产物（`Package/`、`*.xcarchive`、`*.app/`、`*.pkg`）。
  **保留** `docs/benchmarks/` 下的公开性能报告（只忽略 `benchmarks/local-*.json`）。
- `Tests/AcceptanceTests/ReleaseCapabilityAcceptanceTests.swift` 新增五条**可运行的泄露回归测试**，
  直接扫描 `docs/benchmarks/*.json` 并**逐字段遍历解析后的值**（而不是对原文做字符串 `contains`），
  断言其中不出现用户名、外置盘名、凭据、会话标识、绝对本地路径与路径级字段名。
  问题 1 修复后**无需任何例外白名单**即可全绿。

## 4. 尚未完成、需要主控或用户决定的事

| 事项 | 现状 | 卡在哪 |
| --- | --- | --- |
| 仓库名称与地址 | 品牌已定为**寻目 · Xunmu**（工程代号 MacEverything）；用户已确认公开仓库 `qitiandashenggogogo/xunmu` | 品牌版已通过 429 项本地测试；公开源码已上传，采用脱敏快照 |
| GitHub 账号 | 已登录 `qitiandashenggogogo` | 账户与公开目标已确认 |
| 签名与公证 | 已用本机 `Godox Dev` 自签名完成构建与严格验签；**无 Apple Developer ID、无公证** | 用户明确没有付费开发者账号 |
| 自动更新 | 代码已接入 Sparkle 2（菜单、后台检查、会话保存、缺配置时明确禁用），**但真实网络升级仍不可用**：缺更新源地址、缺 Ed25519 密钥对、缺更新包与 appcast 托管，**真实旧版→新版网络升级从未验收过**；交付包内保持禁用状态 | 见 [UPDATES.md](UPDATES.md) |
| 崩溃/诊断上报 | **本地部分已完成、已验证；远程未接通、未验证**。`SearchDiagnostics` 是本地零依赖模块，**不联网、不上传任何崩溃或诊断数据**，本地诊断导出（开启→记录→导出/撤回）已由验收套件覆盖。**崩溃捕获与远程上报都未接通**——**“已完成”不等于“有远程上报”** | 若将来新增外发上报：需先取得用户明确同意，且默认不含文件名、路径、搜索词与文件内容 |
| 同事首次安装 / 跨版本升级 | **未验证** | 需要真实同事 Mac 与真实安装包 |
| 公开性能报告里的临时路径 | 问题 1 已在工作树修复（手工脱敏） | 已完成，但工具侧尚无脱敏步骤，重跑会复现 |
| 本地交付包 | **已在本地构建并验签通过**：app 与 Sparkle 各嵌套组件 `codesign --verify --deep --strict` 全部返回 0；整包 `--smoke` 通过；本地 zip 已生成 | 应用 ZIP 仅本地准备，未上传 Release；源码已公开，未接诊断接收服务 |
| Sparkle 许可声明随包分发 | **已完成**：2026-10-12 主控实际打包后，包内 `Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE` 已存在 | 已验证；保留完整许可文件 |

## 5. 发布前检查清单

- [x] MIT 许可证就位，版权行为 "2026 MacEverything contributors"
- [x] 第三方许可表登记完毕（SQLite 为公有领域；Sparkle 2.10.0 为 MIT）
- [x] Sparkle 的 MIT 许可声明随包分发（`Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE`，
      2026-10-12 实际打包记录；日志 `~/Library/Caches/MacEverything/lead-package-20261012.log`）
- [x] 本机用户名、外置卷名、凭据、调度标识审计完成；**审计文档与源码自身均不复述任何私有标识**
      （用户名与额外卷名改为运行期取得／环境注入；注入内容不公开）
- [x] 泄露回归测试已加入验收套件；**注入配置非法时显式失败**，不会因配置拼错而假绿
- [x] `.gitignore` 覆盖诊断、凭据、打包中间产物
- [x] `docs/benchmarks/2026-10-09-100k.json` 的临时路径脱敏（问题 1）
- [x] 2026-10-12 百万条合成报告入库前逐字段核查，无私有路径与标识
- [ ] 把报告脱敏做成工具/导出步骤，避免重跑基准时重新写出本机临时路径
- [x] 用户已确认公开仓库名称与地址：`qitiandashenggogogo/xunmu`
- [x] 新品牌代码最终验收：429 项测试通过；公开源码采用脱敏快照
- [ ] 在真实安装环境验证首次安装与**真实跨版本**升级（见 [SIGNING.md](SIGNING.md)）
      —— 当前验收矩阵里只有「同一份代码重开索引」，不等于跨版本升级
- [x] 保留本地历史；公开仓库采用已检查的源码快照，避免上传旧临时路径

## 6. 相关文档

- 许可：[LICENSE](../LICENSE)
- 开源借鉴与致谢：[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)
- 签名与安装：[SIGNING.md](SIGNING.md)
- 实际验证范围与性能数据：[VALIDATION.md](VALIDATION.md)
- 模块契约：[INTERFACES.md](INTERFACES.md)