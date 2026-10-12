import Foundation
import Testing
@testable import SearchUI

/// 高级筛选与扩展名解析测试（纯逻辑，无 GUI）。
@Suite("筛选解析")
struct FilterParsingTests {

    private let mb: Int64 = 1 << 20
    private let kb: Int64 = 1024
    private let gb: Int64 = 1 << 30

    // MARK: - 扩展名

    @Test("扩展名解析：分隔符、去重、大小写、点前缀")
    func extensionParser() {
        #expect(ExtensionFilterParser.parse("pdf") == ["pdf"])
        #expect(ExtensionFilterParser.parse("pdf,docx") == ["pdf", "docx"])
        #expect(ExtensionFilterParser.parse("pdf，docx；txt") == ["pdf", "docx", "txt"])
        #expect(ExtensionFilterParser.parse("*.PDF") == ["pdf"])
        #expect(ExtensionFilterParser.parse("pdf pdf PDF") == ["pdf"])
        #expect(ExtensionFilterParser.parse("").isEmpty)
        #expect(ExtensionFilterParser.parse("  , ; ").isEmpty)
        #expect(ExtensionFilterParser.parse("archive.tar.gz").isEmpty, "带点的整名不当作扩展名")
    }

    // MARK: - 大小

    @Test("空表达式表示不限")
    func emptySizeExpression() throws {
        let parsed = try AdvancedFilterResolver.parseSizeExpression("   ")
        #expect(parsed.min == nil)
        #expect(parsed.max == nil)
    }

    @Test("纯数值表示下限")
    func plainSizeIsMinimum() throws {
        let parsed = try AdvancedFilterResolver.parseSizeExpression("10mb")
        #expect(parsed.min == 10 * mb)
        #expect(parsed.max == nil)
    }

    @Test("裸数字按字节")
    func bareNumberIsBytes() throws {
        #expect(try AdvancedFilterResolver.parseSizeExpression("512").min == 512)
    }

    @Test("比较运算符")
    func comparisonOperators() throws {
        #expect(try AdvancedFilterResolver.parseSizeExpression(">10mb").min == 10 * mb + 1)
        #expect(try AdvancedFilterResolver.parseSizeExpression(">=10mb").min == 10 * mb)
        #expect(try AdvancedFilterResolver.parseSizeExpression("<2gb").max == 2 * gb - 1)
        #expect(try AdvancedFilterResolver.parseSizeExpression("<=2gb").max == 2 * gb)
        #expect(try AdvancedFilterResolver.parseSizeExpression("=5kb").min == 5 * kb)
    }

    @Test("严格大于 0 不能退化成 >=0")
    func strictGreaterThanZeroIsOneByte() throws {
        #expect(try AdvancedFilterResolver.parseSizeExpression(">0").min == 1)
    }

    @Test("区间写法")
    func range() throws {
        for text in ["1mb-5mb", "1mb ~ 5mb", "1mb至5mb", "1MB—5MB"] {
            let parsed = try AdvancedFilterResolver.parseSizeExpression(text)
            #expect(parsed.min == mb, "下限解析失败：\(text)")
            #expect(parsed.max == 5 * mb, "上限解析失败：\(text)")
        }
    }

    @Test("小数尺寸")
    func fractionalSize() throws {
        #expect(try AdvancedFilterResolver.parseSizeExpression("1.5mb").min == Int64(Double(mb) * 1.5))
    }

    @Test("中文单位")
    func chineseUnit() throws {
        #expect(try AdvancedFilterResolver.parseSizeExpression("2兆字节").min == 2 * mb)
        #expect(try AdvancedFilterResolver.parseSizeExpression("1千字节").min == kb)
    }

    @Test("非法大小被拒绝", arguments: ["abc", "10zz", "mb", "-5mb"])
    func invalidSizeThrows(text: String) {
        #expect(throws: FilterParseError.invalidSize(text)) {
            _ = try AdvancedFilterResolver.parseSizeExpression(text)
        }
    }

    @Test("上下限颠倒被拒绝")
    func invertedRangeThrows() {
        #expect(throws: FilterParseError.minGreaterThanMax) {
            _ = try AdvancedFilterResolver.parseSizeExpression("5mb-1mb")
        }
    }

    // MARK: - 组合解析

    @Test("组合解析出全部条件")
    func resolveAllFields() throws {
        let after = Date(timeIntervalSince1970: 1_000_000)
        let before = Date(timeIntervalSince1970: 2_000_000)
        let values = AdvancedFilterValues(
            minSizeText: "10mb",
            maxSizeText: "2gb",
            useModifiedAfter: true,
            modifiedAfter: after,
            useModifiedBefore: true,
            modifiedBefore: before,
            caseSensitive: true
        )
        let resolved = try AdvancedFilterResolver.resolve(values)
        #expect(resolved.minSize == 10 * mb)
        #expect(resolved.maxSize == 2 * gb)
        #expect(resolved.modifiedAfter == after)
        #expect(resolved.modifiedBefore == before)
        #expect(resolved.caseSensitive == true)
    }

    @Test("日期勾选关闭时不给条件")
    func disabledDateCheckboxesProduceNil() throws {
        let values = AdvancedFilterValues(
            minSizeText: "",
            maxSizeText: "",
            useModifiedAfter: false,
            modifiedAfter: Date(timeIntervalSince1970: 1),
            useModifiedBefore: false,
            modifiedBefore: Date(timeIntervalSince1970: 2),
            caseSensitive: false
        )
        let resolved = try AdvancedFilterResolver.resolve(values)
        #expect(resolved.modifiedAfter == nil)
        #expect(resolved.modifiedBefore == nil)
        #expect(resolved.minSize == nil)
        #expect(resolved.maxSize == nil)
    }

    @Test("最小大于最大被拒绝")
    func resolveRejectsMinGreaterThanMax() {
        let values = AdvancedFilterValues(minSizeText: "2gb", maxSizeText: "1mb")
        #expect(throws: FilterParseError.minGreaterThanMax) {
            _ = try AdvancedFilterResolver.resolve(values)
        }
    }

    @Test("日期倒序被拒绝")
    func resolveRejectsInvertedDates() {
        let values = AdvancedFilterValues(
            useModifiedAfter: true,
            modifiedAfter: Date(timeIntervalSince1970: 2_000_000),
            useModifiedBefore: true,
            modifiedBefore: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(throws: FilterParseError.minGreaterThanMax) {
            _ = try AdvancedFilterResolver.resolve(values)
        }
    }

    @Test("尺寸回显可再解析")
    func sizeTextRoundTrip() throws {
        #expect(AdvancedFilterResolver.sizeText(for: nil) == "")
        #expect(AdvancedFilterResolver.sizeText(for: 10 * mb) == "10MB")
        #expect(AdvancedFilterResolver.sizeText(for: gb) == "1GB")
        #expect(AdvancedFilterResolver.sizeText(for: 512) == "512B")
        #expect(AdvancedFilterResolver.sizeText(for: 1536) == "1.5KB")
        #expect(try AdvancedFilterResolver.parseSizeExpression(AdvancedFilterResolver.sizeText(for: 10 * mb)).min == 10 * mb)
        #expect(try AdvancedFilterResolver.parseSizeExpression(AdvancedFilterResolver.sizeText(for: 1536)).min == 1536)
    }
}