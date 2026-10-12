import Foundation
import Testing
@testable import SearchUI

@Suite("状态栏消息")
struct StatusMessageTests {
    private struct SampleError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Test("短提示与系统原文分开保存，原文不改写")
    func failureKeepsSystemTextVerbatim() {
        let system = "“/Volumes/外置盘/资料” couldn’t be opened. (Permission denied: errno 13)"
        let message = StatusMessage.failure("无法开始检查。", error: SampleError(text: system))
        #expect(message.text == "无法开始检查。")
        #expect(message.detail == system)
        #expect(!message.text.contains(system), "短提示里不拼接系统原文")
    }

    @Test("空白详情视为没有详情，不显示空的「详情」")
    func blankDetailIsDropped() {
        #expect(StatusMessage("检查完成。").detail == nil)
        #expect(StatusMessage("检查完成。", detail: "  \n").detail == nil)
    }
}
