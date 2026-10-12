import Foundation
import Testing
import SearchCore

@Suite("本机索引空间保护")
struct LocalIndexCapacityTests {
    @Test("剩余空间未知或低于保留值时停止，边界可通过")
    func capacityBoundary() throws {
        #expect(throws: LocalIndexCapacity.CapacityError.self) { try LocalIndexCapacity.require(nil) }
        #expect(throws: LocalIndexCapacity.CapacityError.self) { try LocalIndexCapacity.require(LocalIndexCapacity.reserveBytes - 1) }
        try LocalIndexCapacity.require(LocalIndexCapacity.reserveBytes)
        try LocalIndexCapacity.require(LocalIndexCapacity.reserveBytes + 1)
    }
    @Test("未创建路径可读取已有祖先空间，不落盘")
    func existingAncestor() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capacity-missing-\(UUID().uuidString)/child")
        _ = try #require(LocalIndexCapacity.freeBytes(at: path))
        #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }
}
