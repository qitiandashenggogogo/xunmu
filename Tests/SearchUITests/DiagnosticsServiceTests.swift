import Foundation
import Testing
@testable import SearchUI
import SearchDiagnostics

/// 诊断接线测试：只用隔离的 UserDefaults suite 与系统临时目录，
/// 不触碰任何真实应用数据、用户文件或用户偏好。
@Suite("本地诊断接线")
@MainActor
struct DiagnosticsServiceTests {

    /// 每个用例一套独立 UserDefaults + 一个独立临时目录。
    private func makeService() -> (service: DiagnosticsService, defaults: UserDefaults, directory: URL) {
        let suiteName = "macui.diagnostics.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macui-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (DiagnosticsService(defaults: defaults), defaults, directory)
    }

    /// 读回导出的 JSON 条目（只用于断言结构，不引入生产接口）。
    private func exportedEvents(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [[String: Any]]) ?? []
    }

    @Test("默认关闭：不点同意就不记录")
    func disabledByDefault() async {
        let (service, defaults, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(defaults.bool(forKey: DiagnosticsService.defaultsKey) == false)
        service.record(module: .app, code: .cancelled)
        await service.drain()
        #expect(await service.eventCount == 0, "未同意时不得留下任何记录")
    }

    @Test("同意后才记录")
    func recordsOnlyAfterConsent() async {
        let (service, defaults, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        await service.grantConsentAndEnable()
        #expect(defaults.bool(forKey: DiagnosticsService.defaultsKey) == true)
        service.record(module: .app, code: .applicationError(.database))
        await service.drain()
        #expect(await service.eventCount == 1)
    }

    @Test("撤回后不残留、也不导出撤回前的事件")
    func revokeLeavesNothingBehind() async throws {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        await service.grantConsentAndEnable()
        service.record(module: .app, code: .applicationError(.database))
        service.record(module: .index, code: .indexDatabaseFailure(sqliteCode: 5))
        await service.drain()
        #expect(await service.eventCount == 2)

        await service.revokeConsent()
        #expect(await service.eventCount == 0, "撤回必须连缓冲区一起清空")
        service.record(module: .app, code: .applicationError(.other))
        await service.drain()
        #expect(await service.eventCount == 0, "关闭状态不得记录新事件")

        let url = directory.appendingPathComponent("after-revoke.json")
        #expect(try await service.export(to: url) == 0, "撤回后不应导出旧记录")
        #expect(try exportedEvents(at: url).isEmpty, "导出内容应为空数组")
    }

    @Test("快速 开启→关闭→导出：操作按顺序串行，不导出旧事件")
    func rapidToggleThenExportIsSerialized() async throws {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 故意不 await，制造连击：开启、记录、撤回、导出连续入队。
        service.record(module: .app, code: .applicationError(.database)) // 未开启：应被丢弃
        await service.grantConsentAndEnable()
        service.record(module: .app, code: .applicationError(.database))
        await service.revokeConsent()
        let url = directory.appendingPathComponent("rapid.json")
        let count = try await service.export(to: url)

        #expect(count == 0, "撤回在导出之前生效时不得导出撤回前的事件")
        #expect(await service.eventCount == 0)
    }

    @Test("开启→记录→导出：串行后内容正确")
    func recordThenExportKeepsOrder() async throws {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        await service.grantConsentAndEnable()
        service.record(module: .app, code: .applicationError(.volumeUnavailable))
        service.record(module: .scanner, code: .scanSyscallFailure(errno: 13))
        await service.drain()

        let url = directory.appendingPathComponent("ordered.json")
        let count = try await service.export(to: url)
        #expect(count == 2)
        let events = try exportedEvents(at: url)
        #expect(events.count == 2)
        #expect(events.compactMap { $0["module"] as? String } == ["app", "scanner"],
                "导出必须保持记录顺序")
        #expect(events[0]["code"] != nil)
        // errno 只能作为小整数出现；不应出现任何自由文本字段。
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        #expect(serialized.contains("errno"))
        #expect(!serialized.contains("localizedDescription"))
        #expect(!serialized.contains("/Users/"))
    }

    @Test("清除后才宣布已清空")
    func clearReportsAfterCompletion() async {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        var messages: [StatusMessage] = []
        service.setStatusHandler { messages.append($0) }

        await service.grantConsentAndEnable()
        service.record(module: .app, code: .cancelled)
        await service.drain()
        await service.clear()

        // 只清内存缓冲：说明里必须讲清已导出的文件不受影响。
        #expect(messages.last == StatusMessage("已清空临时诊断记录。已导出的文件不受影响。"))
        #expect(await service.eventCount == 0)
    }

    @Test("导出失败会被记录为诊断模块自身故障")
    func exportFailureIsRecorded() async {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        await service.grantConsentAndEnable()
        // 目标是一个目录，写入必然失败。
        do {
            _ = try await service.export(to: directory)
            Issue.record("导出到目录应当失败")
        } catch {
            await service.drain()
            let events = await service.diagnosticsEventsForTesting()
            #expect(events.contains { $0.code == .diagnosticsInternalFailure })
        }
    }

    @Test("导出失败：系统原文只留在状态详情里，不进诊断记录")
    func exportFailureDetailStaysOutOfDiagnostics() async throws {
        let (service, _, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        var messages: [StatusMessage] = []
        service.setStatusHandler { messages.append($0) }
        await service.grantConsentAndEnable()

        // 目标是一个目录，写入必然失败；走的是面板选完路径后的同一条反馈路径。
        await service.finishExport(to: directory)
        let failure = try #require(messages.last)
        #expect(failure.text == "诊断导出失败。", "先给白话短提示")
        let detail = try #require(failure.detail, "系统详细信息必须保留，供本机「详情」查看")
        #expect(!detail.isEmpty)

        // 诊断里只能有封闭代号：再导出一次，原文与短提示都不得出现。
        let url = directory.appendingPathComponent("after-failure.json")
        let count = try await service.export(to: url)
        #expect(count >= 1, "导出失败本身应留下一条代号事件")
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!raw.contains(detail), "系统原文不得写进诊断记录")
        #expect(!raw.contains(failure.text), "界面提示文字不得写进诊断记录")
    }
}
