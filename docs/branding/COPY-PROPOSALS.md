# MacEverything / 速寻 界面与功能文案重构提案 (2026-10-12 终态审阅版)

> **设计定位**：产品经理 + 苹果人机工程文案视角  
> **指导思想**：《Don't Make Me Think》（不让用户思考，去除工程黑话）+《写给大家看的设计书》（亲密性、对齐、对比、重复一致性）  
> **品牌定案说明**：用户已于 2026-10-12 选定 **“寻目 · Xunmu”** 为正式品牌。本文对照表中 `[应用名]` 均等长对应 2 字“寻目”（例如“关于[应用名]”实装为 4 汉字“关于寻目”）。  
> **决策与实施基线**：用户已确认采纳本提案，并明确选定**“短提示＋详细报错（选项 A）”**与 5 字“在访达显示”。**表内原文案为改写前基线，完整保留作实施比对与决策档案**；代码所有者正据此推进生产代码接入。  
> **规格与校验口径（重要）**：  
> 1. **固定功能/菜单名称**：严格 **2–5 个汉字**（标点符号如省略号不计入；`[应用名]` 按实装的 2 字“寻目”对待；输入示例、计数、动态文件名与路径等**非固定功能名称**，单独列为动态标签并直接保留实际变量数据）；  
> 2. **辅助说明与提示**：每句严格 **不超过 20 个固定文本字符**（包括汉字、英文字母、数字和标点符号全部计入；不以“只统计汉字”让超长英文虚假过关；动态变量占位符如 `\(count)`、`\(volume.name)` 扣除其占位表达式本身后，外围固定文字单独受此限制）；  
> 3. **系统动态错误例外**：底层捕获的 `error.localizedDescription` 属于运行期系统动态报错，经用户确认作为字数例外完整保留；**仅在本地展示，不新增原文日志，不自动上传**；  
> 4. **保真底线**：功能完全不改；原字串严格逐字取材自源码基线；绝不为了短而改变范围、安全条件或状态真实性。

---

## 目录
1. [关于“后台”概念的梳理与澄清](#一关于后台概念的梳理与澄清)
2. [文案重构核心原则](#二文案重构核心原则)
3. [第 1 组：应用菜单（Menu Bar）](#第-1-组应用菜单menu-bar)
4. [第 2 组：工具栏与主界面导航（Toolbar & Navigation）](#第-2-组工具栏与主界面导航toolbar--navigation)
5. [第 3 组：搜索与高级筛选面板（Search & Advanced Filters）](#第-3-组搜索与高级筛选面板search--advanced-filters)
6. [第 4 组：结果列表、表头与右键操作（Results & Context Menu）](#第-4-组结果列表表头与右键操作results--context-menu)
7. [第 5 组：索引检查、状态栏与安全拦截（Index, Status & Security）](#第-5-组索引检查状态栏与安全拦截index-status--security)
8. [第 6 组：软件更新提示（Software Updates）](#第-6-组软件更新提示software-updates)
9. [第 7 组：本地诊断与隐私声明（Diagnostics & Privacy）](#第-7-组本地诊断与隐私声明diagnostics--privacy)
10. [需用户确认的真实待问项与动态错误处理说明](#十需用户确认的真实待问项与动态错误处理说明)

---

## 一、关于“后台”概念的梳理与澄清

用户原始指令提及：*“重写我后台所有菜单和功能文案”*。

经过对项目全部源码的全面核查，事实确认如下：
* **本项目为纯粹的 macOS 14+ 原生桌面应用（AppKit）**，架构上完全没有部署在云端的 Web Admin、管理控制台或 SaaS 后台服务。
* 在桌面效率工具语境中，用户所称的“后台”对应的是客户端自身的系统控制面：
  1. **菜单栏（Menu Bar）及关于、设置、诊断与更新菜单**；
  2. **高级筛选面板（Advanced Filter Sheet Panel）**；
  3. **底层索引检查、磁盘变动跟踪、安全拦截门禁及本地诊断存储**。
* **交付边界**：本提案全量覆盖上述客户端控制面与状态文案。绝不凭空编造不存在的 Web 页面；若用户长远规划中确实需要一套单独的云端/Web 管理后台，已在第十章单独列出提问。

---

## 二、文案重构核心原则

1. **清晰动词优先，去除工程黑话（Don't Make Me Think）**：
   * 杜绝“枚举”、“代际”、“回放”、“换代”等技术实现词汇。
   * 采用 Mac 用户最熟悉的生活化动词（“查找”、“检查”、“打开”、“加入”）。
2. **术语降维与概念一致性（Repetition / 重复）**：
   * 同一个动作全应用统称：统称为“**检查**”或“**更新记录**”，不混淆“扫描”、“校验”与“重新加载”。
   * “卷（Volume）”降维为日常说法“**磁盘**”。
   * 严守“本地索引目录”与“实时磁盘文件系统”的边界：绝不将索引视图误导为实时磁盘浏览。
3. **安全与状态事实高度真实，绝不为缩略而夸大**：
   * **离线状态**：磁盘未连接不等于物理“已拔出”，更绝不等于“文件已被删除”；在重新连线核验前，绝不说“文件未丢失”或“插回即可直接打开”。
   * **更新状态**：未配更新源如实说明“更新未启用”或“未配置”，绝不能说成“暂无更新”或“已是最新版本”；本地配置齐全如实说“更新已配置”，绝不说成“已成功连上服务器”。
   * **诊断隐私**：如实说明“诊断仅在内存临时缓冲，导出时才写文件，这些记录绝不自动上传网络”；绝不扩大说成“整个应用永不联网”（因为软件更新可以联网），也绝不混淆为“崩溃捕获”。

---

## 三、原文案 → 新文案 完整对照表

---

### 第 1 组：应用菜单（Menu Bar）

覆盖源文件：`Sources/MacEverything/MacEverythingApp.swift`、`Sources/SearchUI/AppUpdateController.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 主菜单 · App项<br>`MacEverythingApp.swift:26` | 关于速寻 | 关于[应用名] | 查看版本与版权信息。 | 4字。保留 macOS 标准规范；待最终定名后填入。 |
| 主菜单 · 退出项<br>`MacEverythingApp.swift:28` | 退出速寻 | 退出[应用名] | 退出并保存当前窗口状态。 | 4字。标准退出动词，简短明确。 |
| 菜单栏 · 编辑<br>`MacEverythingApp.swift:33` | 编辑 | 编辑 | — | 2字。保持系统标准菜单名，不无故改动。 |
| 编辑子菜单 · 复制<br>`MacEverythingApp.swift:34` | 复制 | 复制 | — | 2字。原生标准快捷操作（⌘C）。 |
| 编辑子菜单 · 粘贴<br>`MacEverythingApp.swift:35` | 粘贴 | 粘贴 | — | 2字。原生标准快捷操作（⌘V）。 |
| 编辑子菜单 · 全选<br>`MacEverythingApp.swift:36` | 全选 | 全选 | — | 2字。原生标准快捷操作（⌘A）。 |
| 更新菜单项<br>`AppUpdateController.swift:140` | 检查更新… | 检查更新… | 查找是否有新版本可用。 | 4字。符合苹果官方 App 菜单标准交互规范。 |
| 更新菜单项<br>`AppUpdateController.swift:144` | 自动检查更新 | 自动查更新 | 有新版时主动提醒。 | 5字。原文6字超标，压至5字，口语自然。 |
| 诊断菜单项<br>`MacEverythingApp.swift:68` | 记录本地诊断 | 记录诊断 | 仅在本地临时缓冲排错事件。 | 4字。原文6字超标，压至4字，通俗易懂。 |
| 诊断菜单项<br>`MacEverythingApp.swift:73` | 导出诊断… | 导出诊断… | 保存诊断日志到本地文件。 | 4字。保留省略号表示将弹出保存窗口。 |
| 诊断菜单项<br>`MacEverythingApp.swift:77` | 清除诊断 | 清空诊断 | 清空内存中的临时排错记录。 | 4字。说明明确指出只清内存临时缓冲。 |
| 诊断菜单项<br>`MacEverythingApp.swift:82` | 生成诊断报告… | 生成报告… | 此功能尚未启用。 | 4字。**代码中本项 isEnabled = false 为占位项**，如实标注未启用，不杜撰分析。 |
| 启动错误弹窗标题<br>`MacEverythingApp.swift:51` | 无法打开本地索引 | 打不开记录 | 无法读取已保存的记录。 | 5字。用“记录”解释本地索引，保留失败含义。 |
| 启动错误弹窗说明<br>`MacEverythingApp.swift:52` | `\(error.localizedDescription)\n请检查本机存储目录的权限与剩余空间。` | `\(error.localizedDescription)\n请检查存储目录权限与空间。` | 请检查存储目录权限与空间。 | 动态弹窗正文。系统错误字符串保留原样，表内以字面量换行符展示。 |

---

### 第 2 组：工具栏与主界面导航（Toolbar & Navigation）

覆盖源文件：`Sources/SearchUI/SearchWindowController.swift`、`Sources/MacEverything/AppController.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 主窗口标题栏<br>`AppController.swift:78` | 速寻 · 文件名搜索 | [应用名]搜索 | 快速查找本地与外接文件。 | 4字。窗口主标题，简短大气。 |
| 主搜索框占位符<br>`SearchWindowController.swift:251` | 搜索文件名（任意位置子串，可只输入一两个字） | 搜索文件名 | 输一两个字，也能快速找到。<br>支持匹配名称中的任意片段。 | 输入框占位符，5字。核心解释放到提示标签，“任意位置子串”是技术黑话，改为“任意片段”。 |
| 磁盘下拉默认项<br>`SearchWindowController.swift:580` | 全部卷 | 全部磁盘 | 搜索所有已加入的磁盘。 | 4字。“卷”是底层术语，日常统称“磁盘”。不是全盘所有文件，仅限已加入的位置。 |
| 磁盘下拉离线项<br>`SearchWindowController.swift:582` | `\(volume.name)（离线）` | `\(volume.name)（未连接）` | 当前未连接，但仍可查找。 | 动态下拉项。保留原 `volume.name` 变量；离线不一定拔出，用“未连接”更准确。 |
| 磁盘选择器旁注<br>`SearchWindowController.swift:892` | 卷筛选 | 选择磁盘 | 缩小搜索所在的磁盘范围。 | 4字。去掉生硬的“筛选”二字。 |
| 后缀输入占位符<br>`SearchWindowController.swift:260` | 扩展名，如 pdf,docx | 文件后缀 | 如 pdf、png 或 docx。 | 4字。“扩展名”对非技术用户略显抽象，“后缀”更直白。 |
| 后缀框辅助标识<br>`SearchWindowController.swift:898` | 扩展名筛选 | 按类型搜 | 仅查找指定格式的文件。 | 4字。动词打头，清晰易懂。 |
| 仅文件夹复选框<br>`SearchWindowController.swift:72` | 仅文件夹 | 只看文件夹 | 列表中隐藏普通单文件。 | 5字。日常口语，比“只看目录”更通俗亲切。 |
| 高级筛选按钮<br>`SearchWindowController.swift:73` | 高级… | 高级筛选 | 展开时间与大小细化条件。 | 4字。保留原有功能指向。 |
| 添加位置按钮<br>`SearchWindowController.swift:74` | 添加范围 | 添加位置 | 选择新文件夹或移动硬盘。 | 4字。“范围”抽象，改用日常用词“位置”。 |
| 范围选择弹窗标题<br>`AppController.swift:264` | 选择要索引的文件夹或外置卷 | 选择文件夹 | 可选本机目录或外接硬盘。<br>记录建立后，断开也能搜。 | 5字。精炼窗口标题，原长标题拆为短说明。明确记录建立后断开也能搜。 |
| 范围选择确定按钮<br>`AppController.swift:265` | 建立索引 | 加入搜索 | 整理文件名，方便后续快搜。 | 4字。“建立索引”是技术实现，“加入搜索”是用户目的。 |
| 重新检查按钮<br>`SearchWindowController.swift:75` | 重新校验 | 重新检查 | 同步最新的文件变动。 | 4字。“校验”带校验和误解，日常就是“检查变动”。 |
| 暂停/继续按钮<br>`SearchWindowController.swift:76, 317` | 暂停 / 继续 | 暂停 / 继续 | 临时停止后台文件检查。<br>随时点击即可接着进行。 | 2字。经典简短词，完全保留。 |
| 工具栏 · 暂停提示<br>`SearchWindowController.swift:318` | 暂停索引 / 继续索引 | 暂停/继续 | 暂停时提示“继续检查”。<br>运行时提示“暂停检查”。 | 4字。按按钮当前状态动态切换对应4字提示。 |
| 浏览直接内容按钮<br>`SearchWindowController.swift:77` | 进入此目录 | 浏览此处 | 只查看此文件夹直接内容。 | 4字。非递归操作，明确只看直接内容，避免“此层/目录”过度术语。 |
| 历史后退按钮<br>`SearchWindowController.swift:78` | 后退 | 后退 | 返回上一次的搜索状态。 | 2字。标准导航动作，保留。 |
| 历史前进按钮<br>`SearchWindowController.swift:79` | 前进 | 前进 | 前往后退前的搜索结果。 | 2字。标准导航动作，保留。 |

---

### 第 3 组：搜索与高级筛选面板（Search & Advanced Filters）

覆盖源文件：`Sources/SearchUI/AdvancedFilterPanel.swift`、`Sources/SearchUI/FilterParsing.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 面板字段 · 文件大小<br>`AdvancedFilterPanel.swift:47` | 大小 | 文件大小 | 按文件大小筛选。 | 4字。精准反映文件长度，去除“占用磁盘空间”的不准确说法。 |
| 无障碍 · 最小大小<br>`AdvancedFilterPanel.swift:45` | 最小文件大小 | 最小大小 | 无障碍辅助标签。 | 4字。补齐遗漏的无障碍标签。 |
| 无障碍 · 最大大小<br>`AdvancedFilterPanel.swift:46` | 最大文件大小 | 最大大小 | 无障碍辅助标签。 | 4字。补齐遗漏的无障碍标签。 |
| 大小输入占位符<br>`AdvancedFilterPanel.swift:83` | 如 10mb / >10mb / 1mb-5mb | 如 10mb 或 >5mb | 支持大小范围与比较符号。 | 输入示例。精简占位符示范，降低视觉认知负荷。 |
| 面板字段 · 起始时间<br>`AdvancedFilterPanel.swift:14` | 修改时间从 | 起始时间 | 仅查找在此之后修改过的。 | 4字。原“修改时间从”带介词略别扭。 |
| 时间连接词<br>`AdvancedFilterPanel.swift:16` | 到 | 截至 | 截止到的变动日期。 | 2字。“截至”比口语“到”在表格中更齐整。 |
| 包含当天选项<br>`AdvancedFilterPanel.swift:20` | 结束日期含当天 | 包含当天 | 截止日当天的文件也算入。 | 4字。原7字超标，精炼至4字直击核心。 |
| 大小写选项<br>`AdvancedFilterPanel.swift:18` | 区分大小写 | 区分大小写 | 严格区分英文字母大小写。 | 5字。保留原5字标准译名，比“匹配大小写”更符合习惯。 |
| 面板按钮 · 应用<br>`AdvancedFilterPanel.swift:72` | 应用 | 应用筛选 | 使选定的条件立即生效。 | 4字。避免单一“应用”与系统 App 产生歧义。 |
| 面板按钮 · 清除<br>`AdvancedFilterPanel.swift:75` | 清除 | 清空条件 | 重置所有高级筛选设置。 | 4字。表达更明确。 |
| 筛选输入错误提示<br>`AdvancedFilterPanel.swift:151` | 筛选条件无效，请检查大小或日期输入。 | 格式有误 | 大小或日期填写不正确。<br>请检查输入格式后重试。 | 4字。原超长提示拆为两句短句（每句≤20字）。 |
| 大小解析错误<br>`FilterParsing.swift:34` | 无法识别的大小：\(text) | 大小有误 | 无法识别指定的大小格式。<br>示例：可填写 10MB。 | 4字。拆成两句短语，不把动态错误堆叠为难读长句。 |
| 大小颠倒错误<br>`FilterParsing.swift:36` | 最小大小不能大于最大大小 | 大小颠倒 | 最小值不能大于最大值。 | 4字。日常白话，保留“最小值/最大值”原意，不用时间式起始截止。 |

---

### 第 4 组：结果列表、表头与右键操作（Results & Context Menu）

覆盖源文件：`Sources/SearchUI/TypeIconCache.swift`、`Sources/SearchUI/ResultRows.swift`、`Sources/SearchUI/SearchWindowController.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 表头列 1 · 文件名<br>`TypeIconCache.swift:15` | 名称 | 名称 | 文件或文件夹的名字。 | 2字。标准列名，保留。 |
| 表头列 2 · 路径<br>`TypeIconCache.swift:16` | 路径 | 所在位置 | 文件在磁盘中的目录层级。 | 4字。“所在位置”比“路径”更具现实物理感。 |
| 表头列 3 · 体积<br>`TypeIconCache.swift:17` | 大小 | 大小 | 文件的大小数据。 | 2字。标准列名，去除“占用空间”误导。 |
| 表头列 4 · 修改时间<br>`TypeIconCache.swift:18` | 修改时间 | 修改时间 | 文件最近一次变动的时间。 | 4字。标准列名，保留。 |
| 表头列 5 · 所属卷<br>`TypeIconCache.swift:19` | 卷 | 所在磁盘 | 文件实际存放的磁盘名称。 | 4字。“卷”改称为“所在磁盘”，更加生活化。 |
| 表头列 6 · 状态标记<br>`TypeIconCache.swift:20` | 状态 | 状态 | 当前记录是否在线或待查。 | 2字。标准列名，保留。 |
| 状态标记 · 正常在线<br>`ResultRows.swift:105` | 正常 | 正常 | 磁盘在线，打开时核验。 | 2字。**不保证“可随时打开”**，运行时仍须核验。 |
| 状态标记 · 离线<br>`ResultRows.swift:103` | 离线 | 未连接 | 磁盘当前未连接。<br>重新连接后再行查看。 | 3字。离线不等于拔出，**绝不说“文件未丢/插回即开”**，未在线核验前不轻率承诺。 |
| 状态标记 · 待校验<br>`ResultRows.swift:106` | 待校验 | 待检查 | 记录尚未完成重新检查。 | 3字。**不证明“刚插回”或“稍候即可正常”**，如实说明待检。 |
| 状态标记 · 未知<br>`ResultRows.swift:107` | 未知 | 未知 | 磁盘状态尚未确认。 | 2字。保留标准描述。 |
| 右键菜单 · 打开<br>`SearchWindowController.swift:691` | 打开 | 打开 | 调用默认程序打开该文件。 | 2字。系统通用标准动词。 |
| 右键菜单 · Finder定位<br>`SearchWindowController.swift:696` | 在 Finder 中显示 | 在访达显示 | 在访达窗口中定位该文件。 | 5字。中文系统统一用“访达”，严控在5字以内（原6字）。 |
| 右键菜单 · 复制路径<br>`SearchWindowController.swift:701` | 复制路径 | 复制路径 | 将完整文件地址存入剪贴板。 | 4字。精准行业通用说法。 |
| 右键菜单 · 快速预览<br>`SearchWindowController.swift:706` | 快速查看 | 快速查看 | 按空格键直接预览内容。 | 4字。对应 Mac 原生 Quick Look 官方译名。 |
| 右键菜单 · 浏览直接内容<br>`SearchWindowController.swift:713` | 进入此目录 | 浏览此处 | 只查看此文件夹直接内容。 | 4字。避免“此层/目录”等术语，明确非递归。 |
| 右键菜单 · 含子级搜索<br>`SearchWindowController.swift:719` | 在此目录中搜索（含子目录） | 搜索此处 | 查找此文件夹及子文件夹。 | 4字。**绝不缩为“搜子目录”而漏掉当前层**，说明明确指出包含当前及子层。 |
| 底部计数标签 · 零结果/初始<br>`SearchWindowController.swift:132` | 共 0 项 | 共 0 项 | 初始无输入或无匹配时显示。 | 4字。**不仅用于未命中，也用于初始状态**，故保留原中性计数。 |
| 底部计数标签 · 命中数<br>`SearchWindowController.swift:446` | 共 \(resultRows.count) 项 | 找到 \(resultRows.count) 项 | 已列出符合条件的文件。 | 动态计数输出。直接保留原变量 `resultRows.count`。 |
| 范围状态标签 · 全部<br>`SearchWindowController.swift:626` | 范围：全部卷 | 所有位置 | 搜索所有已加入的位置。 | 4字。**绝非全盘所有文件**，如实说明是搜索已加入的位置。 |
| 范围状态标签 · 单盘<br>`SearchWindowController.swift:629` | 范围：卷 \(name) | 范围：磁盘 \(name) | 仅在此磁盘内查找。 | 动态范围输出。直接保留原 `name` 变量。 |
| 范围状态标签 · 路径与层级<br>`SearchWindowController.swift:632` | 范围：\(name)/\(path) \(recursive ? "含子目录" : "仅本层") | 范围：\(name)/\(path) \(recursive ? "含子文件夹" : "只看本层") | 保留路径与递归分支。 | 动态范围输出。**代码源码中不含外层括号**，逐字对齐源码并保留全部动态分支。 |

---

### 第 5 组：索引检查、状态栏与安全拦截（Index, Status & Security）

覆盖源文件：`Sources/MacEverything/AppController.swift`、`Sources/SearchUI/FileActions.swift`、`Sources/SearchUI/PublishScheduler.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 初次使用引导<br>`AppController.swift:158` | 添加文件夹或外置卷，建立可离线搜索的本地索引 | 添加位置 | 添加文件夹或移动硬盘。<br>记录建立后，断开也能搜。<br>所有记录保存在本机。 | 4字。原长句拆为3句日常短句，明确记录建立后断开也能搜，不承诺瞬间可查。 |
| 状态栏 · 追赶增量<br>`AppController.swift:384` | 已加载本地索引；正在追赶文件变化 | 同步变动 | 记录已就绪。<br>正在同步最新文件变动。 | 4字。去除“追赶”的工程内部口吻。 |
| 状态栏 · 正在检查<br>`AppController.swift:465` | 正在校验 \(volume.name)；已建立的索引仍可搜索 | 正在检查 | 正在检查 \(volume.name)。<br>已有记录现在仍可搜索。 | 4字。去除“校验”的技术生涩感，保留已有记录可搜的事实。 |
| 状态栏 · 枚举进度<br>`AppController.swift:540` | 正在校验 \(volume.name) · 本次已枚举 \(publishedCount) 项；可先搜索已索引部分 | 正在检查 \(volume.name) · 本次已整理 \(publishedCount) 项 | 现有部分可直接搜索。 | 动态状态输出。保留原 `publishedCount` 变量，杜绝“枚举”术语。 |
| 状态栏 · 检查完毕<br>`AppController.swift:487` | 校验完成；搜索读取本地索引 | 检查完成 | 文件列表已更新。<br>搜索读取本地记录。 | 4字。强调“已更新完成”，不再宣讲架构。 |
| 状态栏 · 扫描暂停（手动）<br>`AppController.swift:285` | 扫描已暂停；已有索引仍可搜索，点击继续可恢复 | 检查已暂停 | 已有记录仍可搜索。<br>随时可继续进行。 | 5字。对应用户手动点击暂停，独立成行。 |
| 状态栏 · 扫描暂停（保存）<br>`AppController.swift:493` | 扫描已暂停，进度已保存；已有索引仍可搜索 | 进度已保存 | 检查已暂停。<br>已有记录仍可继续搜索。 | 5字。对应任务取消保存中断点，独立成行。 |
| 状态栏 · 混合读取失败<br>`AppController.swift:487` | 部分目录未授权或读取失败（\(issueCount)）；保留旧索引，可授权后重新校验 | 部分未读 | 部分位置读取失败。<br>保留旧记录，排查后重检。 | 4字。**混合错误含 I/O 与权限，绝不能统称“权限受限”，也不能保证授权必解**。 |
| 状态栏 · 写入频发<br>`PublishScheduler.swift:227` | 索引正在持续变化，稍后会自动同步。 | 持续变动 | 记录正在持续变化。<br>稍后会自动刷新列表。 | 4字。日常白话解释背压，**不称“检测到大量文件变动”**（少量持续变动同样触发）。 |
| 状态栏 · 恢复索引失败<br>`AppController.swift:233` | 恢复索引失败：\(error.localizedDescription)。已有文件不会被修改。 | 恢复记录失败：\(error.localizedDescription) | 已有文件不受影响。 | 动态错误输出。补齐遗漏行，保留原底层报错变量。 |
| 状态栏 · 保存范围失败<br>`AppController.swift:242` | 无法保存索引范围：\(error.localizedDescription) | 无法保存位置：\(error.localizedDescription) | 搜索位置保存失败。 | 动态错误输出。补齐遗漏行，前缀采用日常用词“位置”。 |
| 状态栏 · 保存状态失败<br>`AppController.swift:249` | 无法保存搜索状态：\(error.localizedDescription) | 无法保存状态：\(error.localizedDescription) | 搜索记录保存失败。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 建立索引失败<br>`AppController.swift:320` | 无法建立索引：\(error.localizedDescription) | 无法加入搜索：\(error.localizedDescription) | 未能建立文件记录。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 监控不可用<br>`AppController.swift:386` | 文件监控不可用，保留已有索引：\(error.localizedDescription) | 监控暂不可用：\(error.localizedDescription) | 已保留现有记录。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 保存进度失败<br>`AppController.swift:441` | 无法保存待扫进度：\(error.localizedDescription) | 无法保存进度：\(error.localizedDescription) | 检查进度保存失败。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 启动扫描失败<br>`AppController.swift:460` | 无法启动扫描：\(error.localizedDescription) | 无法开始检查：\(error.localizedDescription) | 未能启动文件检查。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 扫描中断<br>`AppController.swift:496` | 扫描中断，保留旧索引：\(error.localizedDescription) | 检查已中断：\(error.localizedDescription) | 已保留之前的记录。 | 动态错误输出。补齐遗漏行。 |
| 状态栏 · 版本读取失败<br>`AppController.swift:577` | 索引版本读取失败，保留上一次结果。 | 读版本失败 | 记录读取异常。<br>已保留上次搜索结果。 | 5字。补齐遗漏行。 |
| 状态栏 · 本地读取失败<br>`AppController.swift:611` | 读取本地索引失败，已保留上一次结果；不会用不完整的数据覆盖。 | 读记录失败 | 已保留上次完整结果。<br>避免被不完整数据覆盖。 | 5字。补齐遗漏行。 |
| 安全拦截 · 磁盘离线<br>`FileActions.swift:28` | 该文件所在卷已离线，无法打开。请先连接该卷。 | 磁盘未连 | 磁盘当前未连接。<br>请连接后再试。 | 4字。**未在线核验前绝不说“文件未丢/插回即开”**，如实说明当前未连接。 |
| 安全拦截 · 挂载丢失<br>`FileActions.swift:30` | 找不到该卷的挂载位置，无法打开。卷可能已被拔出。 | 位置失效 | 找不到磁盘连接位置。<br>磁盘可能已拔出或卸载。 | 4字。避免“挂载位置（Mount Point）”术语。 |
| 安全拦截 · 身份无法确认<br>`FileActions.swift:32` | 无法确认该卷身份（缺少可靠卷或分区 UUID），已阻止打开，以免打开错误卷上的同名文件。 | 身份未知 | 缺少可靠磁盘唯一标识。<br>已阻止打开以防认错。 | 4字。保留真实安全防御逻辑：缺少唯一标识，防止认错同名文件。 |
| 安全拦截 · 磁盘被调换<br>`FileActions.swift:34` | 该挂载位置的卷 UUID 与索引记录不一致，疑似换过盘，已阻止打开。请重新校验该范围。 | 磁盘变动 | 连接磁盘与记录不一致。<br>已阻止打开，请重新检查。 | 4字。日常白话表达，不承诺重检必定解决。 |
| 安全拦截 · 路径丢失<br>`FileActions.swift:36` | 找不到该文件，可能已被移动或删除。 | 路径失效 | 找不到目标文件。<br>可能已被移动或删除。 | 4字。日常直白表达，避免冰冷的404感。 |
| 安全拦截 · 身份不一致<br>`FileActions.swift:38` | 该路径上的文件已被替换（与索引记录的文件身份不一致），已阻止打开。请重新校验后重试。 | 文件有变 | 文件特征与记录不符。<br>已阻止打开，排查后重试。 | 4字。**不断言被另一个文件替换**（inode变化只证明身份不符），保留阻止打开与重检建议。 |
| 安全拦截 · 打开失败<br>`FileActions.swift:40` | 系统没能打开该文件。 | 打开失败 | 系统未能打开该文件。 | 4字。**不虚构“文件损坏”等未知原因**，忠于系统调用原意。 |
| 操作反馈 · 路径已复制<br>`FileActions.swift:137` | 已复制路径：\(path) | 路径已复制：\(path) | 文件路径已存入剪贴板。 | 动态反馈输出。直接保留原变量 `path`。 |

---

### 第 6 组：软件更新提示（Software Updates）

覆盖源文件：`Sources/SearchUI/AppUpdateController.swift`、`Sources/SearchUI/UpdateFeedConfiguration.swift`、`Sources/MacEverything/AppController.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 更新弹窗标题<br>`AppUpdateController.swift:153` | 自动更新未启用 | 更新未启用 | 更新服务尚未配置。<br>目前无法检查新版本。 | 5字。**绝不改称“暂无更新”，更不称“已是最新”**；缺配置根本没查服务器。 |
| 更新弹窗按钮<br>`AppUpdateController.swift:155` | 好 | 好的 | — | 2字。日常口语。 |
| 更新会话保护提示<br>`AppController.swift:94` | 更新前已保存会话；索引与缓存不会删除 | 状态已存 | 当前搜索历史已完整保存。<br>现有记录不会被删除。 | 4字。拆成短句，安抚用户数据安全预期。 |
| 更新状态 · 组件未就绪<br>`AppUpdateController.swift:100` | 更新控制器不可用。 | 更新不可用 | 更新组件未能初始化。 | 5字。**不猜测“模块正在启动”**，如实说明当前不可用。 |
| 更新状态 · 启动检查失败<br>`AppUpdateController.swift:110` | 无法启动更新检查：\(error.localizedDescription) | 无法启动更新：\(error.localizedDescription) | 更新检查未能启动。 | 动态错误输出。补齐遗漏行，保留底层报错变量。 |
| 更新状态 · 繁忙<br>`AppUpdateController.swift:128` | 现在不能检查更新，请稍后再试。 | 请稍后再试 | 当前无法检查更新。<br>请稍后再次尝试。 | 5字。口语温和。 |
| 更新状态 · 发现新版<br>`AppUpdateController.swift:199` | 发现新版本 \(item.displayVersionString)，准备下载。 | 发现新版本 \(item.displayVersionString)，准备下载 | 准备开始下载。 | 动态状态输出。直接保留原 `item.displayVersionString` 变量，**绝不写成已能自动安装**。 |
| 更新失败反馈<br>`AppUpdateController.swift:182` | 检查更新失败：\(error.localizedDescription) | 检查更新失败：\(error.localizedDescription) | 无法完成更新检查。 | 动态错误输出。**不一律猜为“网络问题”**，失败原因由待问项单独保留。 |
| 更新未完成<br>`AppUpdateController.swift:193` | 更新未完成：\(nsError.localizedDescription) | 更新未完成：\(nsError.localizedDescription) | 更新过程已中断。 | 动态错误输出。**不保证“安全保持当前版本”**，如实说明过程已中断。 |
| 配置状态 · 就绪<br>`UpdateFeedConfiguration.swift:23` | 自动更新已就绪：\(feedURL.host ?? feedURL.absoluteString) | 更新已配置：\(feedURL.host ?? feedURL.absoluteString) | 本地更新配置完整。 | 动态状态输出。保留原表达式，**仅代表本地配置齐全，绝不说“服务已连接/已连上服务器”**。 |
| 配置缺失 · 缺源<br>`UpdateFeedConfiguration.swift:49` | 未配置更新源：Info.plist 缺少 SUFeedURL，自动更新已禁用。 | 缺少更新源 | 未配置更新服务器地址。<br>自动更新已停用。 | 5字。日常话解释缺少地址，不丢分支区别。 |
| 配置错误 · 源无效<br>`UpdateFeedConfiguration.swift:51` | 更新源地址不合法：SUFeedURL 无法解析为 URL，自动更新已禁用。 | 更新源无效 | 更新服务器地址格式有误。<br>自动更新已停用。 | 5字。保留与“缺少”的区别。 |
| 配置错误 · 非HTTPS<br>`UpdateFeedConfiguration.swift:53` | 更新源必须使用 HTTPS：SUFeedURL 不是 https:// 地址，自动更新已禁用。 | 需安全连接 | 更新网址必须使用 HTTPS。<br>自动更新已停用。 | 5字。保留必须安全连接的原则。 |
| 配置缺失 · 缺密钥<br>`UpdateFeedConfiguration.swift:55` | 未配置更新公钥：Info.plist 缺少 SUPublicEDKey，自动更新已禁用。 | 缺少验证 | 更新验证信息缺失。<br>自动更新已停用。 | 4字。日常白话“缺少验证”，不造“验证钥”黑话。 |
| 配置错误 · 密钥无效<br>`UpdateFeedConfiguration.swift:57` | 更新公钥不合法：SUPublicEDKey 必须是 32 字节 Ed25519 公钥的 Base64，自动更新已禁用。 | 验证无效 | 更新验证信息格式有误。<br>自动更新已停用。 | 4字。日常白话“验证无效”，保留与“缺少”的区别。 |

---

### 第 7 组：本地诊断与隐私声明（Diagnostics & Privacy）

覆盖源文件：`Sources/MacEverything/MacEverythingApp.swift`、`Sources/SearchUI/DiagnosticsService.swift`、`Sources/MacEverything/AppController.swift`、`Sources/SearchDiagnostics/DiagnosticEvent.swift`

| 界面位置与源文件定位 | 原文案（逐字源自代码） | 新文案 (固定2–5字 / 动态保留) | 辅助说明 (每句固定字符≤20) | 改写理由与设计思考 |
|---|---|---|---|---|
| 诊断授权弹窗标题<br>`AppController.swift:130` | 记录本地诊断 | 开启诊断 | 仅用于排查使用故障。 | 4字。动词醒目。 |
| 诊断隐私条款正文<br>`AppController.swift:131-135`<br>`DiagnosticsService.swift:19` | 1. 速寻会只在本机记录错误发生的固定代码与计数，用来定位问题。<br>2. 只在本机记录错误代码与计数，不含文件路径、搜索词或查询内容；不会自动上传，导出后由你自行决定是否分享。<br>3. 这不是崩溃报告：应用崩溃时不会自动生成或上传任何内容。 | 隐私条款 | **拆解为短句，忠实覆盖实际字段与边界**：<br>1. 记录暂存本机内存中。<br>2. 导出时才会写入文件。<br>3. 不记录文件名或路径。<br>4. 不记录任何搜索词。<br>5. 含版本、时间和系统信息。<br>6. 记录错误类型与发生次数。<br>7. 这些记录不会自动上传。<br>8. 清空仅清除临时缓存。<br>9. 已导出的文件不会被清除。<br>10. 不收集崩溃报告。<br>11. 远程上报未接通。 | 4字。**关键边界全面落实**：<br>1. 明确说明“不记录文件名”；<br>2. 补齐版本、时间和系统信息（根据 `DiagnosticEvent` 真实结构），不称“内部模块”黑话，不能独占说仅记代号；<br>3. 明确说明仅在内存临时缓冲，导出才写文件；<br>4. 明确停止/清空只清内存缓冲，不暗示已导出的文件被删除；<br>5. 网络承诺限定为“这些记录不会自动上传”，不扩大成整个 App 绝不联网；<br>6. 明确不是崩溃捕获，远程未接通。每句严格 ≤ 20字。 |
| 诊断弹窗确认按钮<br>`AppController.swift:138` | 继续开启 | 确认开启 | 开始在内存缓冲排错记录。 | 4字。明确授权含义。 |
| 诊断弹窗取消按钮<br>`AppController.swift:139` | 取消 | 暂不开启 | 保持关闭，不记录任何信息。 | 4字。给用户安全退出的掌控感。 |
| 状态栏 · 诊断已启动<br>`DiagnosticsService.swift:63` | 已开始记录本地诊断。\(Self.privacyNotice) | 诊断开启中 | 正在内存缓冲排错信息。<br>记录不会自动上传。 | 5字。状态简短呈现，说明明确为内存缓冲。 |
| 状态栏 · 诊断已停止<br>`DiagnosticsService.swift:72` | 已停止记录本地诊断，并清空已缓冲的记录。 | 诊断已停止 | 已停止记录。<br>内存中的临时记录已清空。 | 5字。明确只清空内存缓冲。 |
| 导出文件窗口标题<br>`DiagnosticsService.swift:125` | 导出本地诊断记录 | 导出诊断 | 选择本地保存路径。 | 4字。标准保存对话框标题。 |
| 导出无记录提示<br>`DiagnosticsService.swift:174` | 没有可导出的诊断记录。 | 暂无记录 | 内存中无诊断记录可导出。 | 4字。说明简短真实。 |
| 导出成功反馈<br>`DiagnosticsService.swift:175` | 已导出 \(count) 条诊断记录到 \(url.lastPathComponent)；文件不会自动上传。 | 已导出 \(count) 条诊断记录到 \(url.lastPathComponent) | 文件绝不会自动上传。 | 动态反馈输出。直接保留原变量 `count` 与 `url.lastPathComponent`，重申记录不会自动外发。 |
| 导出失败反馈<br>`DiagnosticsService.swift:177` | 导出失败：\(error.localizedDescription) | 导出失败：\(error.localizedDescription) | 诊断记录未能写入目标文件。 | 动态错误输出。保留底层报错变量，不伪造原因。 |
| 清除完成反馈<br>`DiagnosticsService.swift:184` | 已清除本地诊断记录。 | 清空成功 | 已清空内存中的诊断缓存。 | 4字。消除歧义，明确只清内存缓存，不影响已导出的文件。 |
| 默认导出文件名<br>`DiagnosticsService.swift:191` | 速寻诊断-\(formatter.string(from: Date())).json | [应用名]诊断-\(formatter.string(from: Date())).json | 默认导出的文件名。 | 动态文件名输出。原字串严格逐字取材自代码，保留 `formatter.string(from: Date())` 表达式。 |

---

## 十、用户已决策事项与动态错误处理规范记录

经主控确认，用户已对关键设计选型作出明确决断，在此作为落地实施的技术规范予以固定：

1. **底层动态系统错误（`error.localizedDescription`）采用选项 A（短提示＋详细报错）**：
   * **决策内容**：用户明确选择**“简短提示后保留系统详细错误”**。
   * **呈现与隐私规范**：
     - **两段式呈现**：界面第一行展示固定短标题/短提示（2–5 汉字），第二行完整保留系统原始报错以供排查。
     - **字数例外**：系统底层抛出的动态错误信息（来自 POSIX / Darwin / SQLite）**明确作为界面文案长度限制的合理例外**，不作生硬的人为截断。
     - **隐私底线不变**：此类详细报错**仅在本地当前 UI 中展示**；诊断服务（`SearchDiagnostics`）现有的脱敏闭环机制保持不变，**绝不新增原文系统错误日志记录，绝不自动上传网络**。
2. **常规操作文案定案**：
   * 客户端控制面范围与定位已确认（原生 macOS 桌面端）；
   * 5 字“**在访达显示**”已确认采纳；
   * 品牌占位符统一替换为已定案的 2 字名称“**寻目**”；
   * 表格中 120 行对照文案作为设计基线档案完整保留，代码所有者正根据本表进行生产代码实装。
