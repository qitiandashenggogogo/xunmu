# 诊断模块（SearchDiagnostics）

本模块提供**本地、离线、脱敏**的错误诊断记录，用于用户主动排查问题。

## 当前已实现

- 强类型事件 `DiagnosticEvent`：固定字段 `schemaVersion / sequence / recordedAt / build / environment / module / code / counter`。
- 封闭枚举：`Module`、`Code`、`ErrorKind`、`Counter`。除 `Build.marketingVersion` / `Build.buildNumber` / `Environment.arch` 外，**没有任何字段接受自由字符串**，且这三个也在构造时封闭校验（版本号仅允许 32 字符内的 `[A-Za-z0-9._+-]`；架构仅允许 `arm64`/`x86_64`，其余一律 `unknown`）。
- **`DiagnosticEvent` 的构造器是 `internal`，只能由 recorder 创建。** 外部无法手造带伪造元数据的事件。
- **`build` / `environment` 由 recorder 在 init 时从运行进程采集、只读挂到每个事件上**；公开 `record(...)` **不接受**这两个参数（上一版接受，是泄露通道，已修）。
- 有界内存环形缓冲 `DiagnosticsRecorder`（actor），默认容量 200，超限丢弃最旧并计数；容量每次写入前重新 clamp 到 `1...10_000`。
- 主动导出 JSON（`export(to:)`，漂亮打印、按 key 排序、ISO8601 时间）。
- 失败以值暴露，不静默吞掉：`DiagnosticsError.bufferFull / exportFailed / recordingDisabled`。
- 记录默认**关闭**（`enabled == false`）；**`setEnabled(false)` 在同一个 actor turn 内原子清空缓冲**，调用方无需也不会忘记单独 `clear()`。
- **`sequence` 一律由 recorder 分配**，不存在重复或逆序；`clear()` 后继续递增，不回退。

## 隐私边界（这是本模块存在的理由）

- **禁止任意文本进包。** `DiagnosticEvent` 的类型面上就没有可以放路径、文件名、搜索词、SQL、凭据、异常原文的字段；构建/架构元数据要么由 recorder 自己采集，要么在构造时封闭校验，不接受调用方传入。
- 特别地，`CatalogError` 携带 `open(path:message:)` / `sqlite(code:message:statement:)`，`ScanError` 携带路径，`FilterParseError.invalidSize(String)` 携带用户输入。调用方必须**先归类再上报**：`DiagnosticsClassifier.classify(_:)` 只按类型名匹配并返回粗粒度 `ErrorKind`，**从不读取 error 携带的任何内容**，因此 SQL/path 不可能经此泄漏。
- **不做 regex 伪脱敏。** 脱敏靠类型封闭，不靠事后过滤字符串；过滤表永远会有漏网。
- 不允许 "unknown nested/string" 之类的兜底附加原文。
- 非 UTF-8 文件名等场景在上游扫描器里就被拒绝（不替换字符、不伪造路径），因此根本不会进入诊断路径。

## 尚未实现 / 尚未接通（请勿在文档或对外沟通中声称已具备）

1. **崩溃捕获未接通。** 原生崩溃不是 Swift `Error`，普通 `do/catch` 无法捕获，也无法伪称捕获。本模块只记录 `do/catch` 能拿到的应用错误。
2. **无远程上报。** 模块内没有任何网络代码（无 URLSession / socket / 上传）。导出只写本地文件，由用户决定是否分享。
3. **没有服务、没有接收地址。** 尚未选型 Sentry / 自建 / 手动。将来若接入，默认在**用户同意后于下一次启动**发送，并在 release 构建用 dSYM 符号化。
4. 未来的诊断接收地址**不得**放在 GitHub 公开 issues；issues 面向公开协作。

## 调用样例（供主控参考）

```swift
let diagnostics = DiagnosticsRecorder()  // 默认关闭

// 用户在设置里打开后：
await diagnostics.setEnabled(true)

// 记录一个扫描错误：只给枚举 + errno，不给路径。
// 注意：没有 environment:/build: 参数——那两个由 recorder 自己采集。
do {
    _ = try FileManager.default.attributesOfItem(atPath: rootPath)
} catch {
    let kind = DiagnosticsClassifier.classify(error)  // 粗粒度归类，不读 error 文本
    try? await diagnostics.record(
        module: .scanner,
        code: .applicationError(kind),
        counter: .scanError)
}

// 用户点击"导出诊断"后：
let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics.json")
let count = try await diagnostics.export(to: url)
// 把 url 交给用户，由用户决定是否分享；模块本身不上传。

// 用户撤回同意：一步即可，缓冲同时被清空。
await diagnostics.setEnabled(false)
```

## 用法约束给调用方

- 不要为了"方便排查"给事件附加 `error.localizedDescription` / `String(describing:)` / path / query —— 类型面上没有这些参数，请不要绕过；也不要试图自造 `DiagnosticEvent`（构造器是 internal）。
- `record` 在关闭状态下抛 `recordingDisabled`，在容量满且 `rejectWhenFull` 时抛 `bufferFull`，默认（`rejectWhenFull == false`）会淘汰最旧并累加 `droppedCount`。
- 序列号 `sequence` 由 recorder 分配且 `clear()` 不回退，便于检测导出文件的缺口。
- `DiagnosticsConfiguration.capacity` 虽是 `public var`、init 后可被改，但 `init`、`setCapacity` 与每次写入都会 clamp 到 `1...10_000`，所以 `0` / `-1` / 巨大值都不会导致崩溃或无界增长。