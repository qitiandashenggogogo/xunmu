# 开源借鉴与致谢声明 (Acknowledgements)

> **项目名称**：寻目 · Xunmu（开发与底层工程代号：MacEverything）  
> **更新时间**：2026-10-12  
> **授权协议**：本项目基于 [MIT 许可证](../LICENSE) 开源。

本项目是一套面向 macOS 14+ 的独立原生文件名搜索工具，由项目贡献者基于 Swift 6、AppKit 与 SQLite 独立开发实现。在此向为本项目提供直接技术依赖、生态支持、交互设计灵感与同类开源调研参考的项目与作者表达诚挚感谢。

---

## 一、实际直接技术依赖

本项目在运行与打包时显式接入并链接的第三方开源依赖如下，各自遵循其独立的开源许可协议：

| 项目 / 库 | 官方出处与许可证链接 | 许可证类型 | 本项目集成方式与授权义务履行 |
|---|---|---|---|
| **Sparkle 2.10.0** | 官方仓库：[sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)<br>许可文件：[Sparkle 2.10.0 LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) | **MIT License**<br>（随附外部许可证：bsdiff、sais-lite、ed25519 等） | **直接框架依赖**（SwiftPM）。用于应用内安全检查软件更新。<br>打包产物内已原样完整保留整个许可文件（含 MIT 主许可及 External Licenses 全文）：`Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE`。 |
| **SQLite** | 官方站点：[sqlite.org](https://www.sqlite.org/)<br>版权声明：[sqlite.org/copyright.html](https://www.sqlite.org/copyright.html) | **Public Domain**<br>（公有领域，作者已放弃版权） | **底层数据引擎**。用于管理内外置盘的文件名持久化元数据。<br>通过 macOS 系统内置的 `libsqlite3` 动态链接，由 `Sources/SearchIndex/SQLiteConnection.swift` 封装使用。 |

---

## 二、产品理念与交互体验启发（非开源代码依赖）

* **Voidtools Everything**  
  * **官方站点**：[voidtools.com](https://www.voidtools.com/)  
  * **创作者**：David Carpenter  
  * **性质说明**：**Windows 平台专有免费软件（Proprietary Freeware），并非开源项目，亦非本项目的代码依赖**。  
  * **启发说明**：Everything 的即时过滤与紧凑结果列表启发了本项目的交互设计。本项目选择只索引文件名和元数据，不搜索文件正文。  
  * **实现区别**：本项目为独立的 macOS 原生实现（基于 Swift 6 与 SQLite），并非 Everything 的移植版本，未包含亦未依赖其专有闭源组件。

---

## 三、同类开源项目调研与参考（非直接运行时依赖）

在技术选型、架构讨论与同类工具调研过程中，以下开源项目的公开设计与代码实践为本项目提供了宝贵的参考资料。本项目未将它们作为直接运行时依赖，在此如实记录其实际出处与参考点：

* **everything-mac**  
  * **官方仓库**：[alesloa/everything-mac](https://github.com/alesloa/everything-mac)  
  * **技术栈与许可证**：全 Swift 实现（SwiftUI / AppKit），基于 **MIT License**。  
  * **参考与交流点**：公开展示了在 macOS 平台上使用 Swift 维护文件名缓冲、并列元数据数组管理，以及结合 FSEvents 监听文件系统变动的原生实现方案。  
  * **实现区别**：本项目结合自身需求，选择了以本地 SQLite 作为持久化真源并辅以内存快照全结果稳定全序排序的架构取舍。感谢该项目在 Mac 原生检索上的先驱探索。
* **Cardinal**  
  * **官方仓库**：[cardisoft/cardinal](https://github.com/cardisoft/cardinal)  
  * **技术栈与许可证**：Rust + Tauri 架构，针对 macOS 文件搜索设计，基于 **MIT License**。  
  * **参考点**：提供了在 macOS 上结合 FSEvents 事件监听、文件名子串检索语法与跨卷搜索生态的现代实现参考。  
  * **实现区别**：本项目未将其作为运行时依赖。早期讨论中曾将其作为同类工具技术线索，在此特予记录致谢。
* **FSearch**  
  * **官方仓库**：[cboxdoerfer/fsearch](https://github.com/cboxdoerfer/fsearch)  
  * **许可文件**：[fsearch LICENSE](https://github.com/cboxdoerfer/fsearch/blob/master/LICENSE)（**GNU GPL-2.0**，GitHub 识别为 GPL-2.0）  
  * **技术栈**：**C 语言 + GTK3**（面向 Linux 桌面）。  
  * **参考点**：作为类 Everything 检索器在 POSIX / Linux 桌面环境下的成熟独立开源实现，为桌面级快速文件名搜索提供了优秀的交互形态与性能参考标杆。  
  * **实现区别**：本项目为 macOS Swift 实现，未将其作为运行时依赖。FSearch 是本次核对的 Linux 同类工具参考，感谢其公开的设计与实现资料。

---

## 四、开发语言与系统平台生态感谢

* **Swift 语言与 Swift Package Manager**  
  * 官方站点：[swift.org](https://www.swift.org/)（Apache 2.0 with Runtime Library Exception）  
  * 感谢 Swift 团队打造的 Swift 6 严格并发检查机制（Sendable / Actor），为多卷异步扫描与跨线程结果调度提供了编译期并发安全保障。
* **macOS 系统 SDK**  
  * 本项目基于 AppKit 原生组件（`NSTableView`, `NSWindow` 等）与 Darwin 系统底层 API 构建。其中卷发现与元数据访问基于 `statfs(2)` 与 URL resource keys，文件变动监听基于 FSEvents。  
  * **独立声明**：本项目为独立开源软件，与 Apple Inc. 无任何官方赞助、从属或背书关系。

---

## 五、应用图标设计说明

* **应用图标（图标 A：文件夹＋放大镜，蓝青配色）**  
  * 由本项目 Swift 脚本（[Scripts/generate-icon-proposals.swift](../Scripts/generate-icon-proposals.swift)）通过 CoreGraphics 矢量 API 原创绘制各尺寸（包含 16px/32px 的像素对齐优化），未引入外部商业图标或开源 Logo 资产。可通过 `swift Scripts/generate-icon-proposals.swift` 在本地随时重新生成。

---

## 六、核验说明与事实公开

* **核查方式说明**：2026-10-12 根据以上官方仓库的 README、LICENSE 与官方站点核对项目链接、技术栈和许可信息。
* **非法律结论声明**：本致谢文档旨在如实向社区说明本项目的灵感来源、直接依赖与调研参考，不作为正式的源码知识产权法律审计报告。
