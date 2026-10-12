import Foundation
import SearchCore

/// 扩展名筛选解析。接受 "pdf"、"pdf,docx"、"*.pdf docx"、"pdf，docx"。
public enum ExtensionFilterParser {
    private static let separators: Set<Character> = [
        ",", ";", "|", "，", "、", "；", " ", "\t", "\n",
    ]

    public static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.split(whereSeparator: { separators.contains($0) }) {
            var value = String(token)
            if value.hasPrefix("*.") { value.removeFirst() }
            while value.hasPrefix(".") { value.removeFirst() }
            value = value.lowercased()
            guard !value.isEmpty, !value.contains(".") else { continue }
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }
}

public enum FilterParseError: Error, Equatable, Sendable, LocalizedError {
    case invalidSize(String)
    case minGreaterThanMax

    public var errorDescription: String? {
        switch self {
        case .invalidSize(let text):
            return "大小格式有误：\(text)。可写 10mb 或 >5mb。"
        case .minGreaterThanMax:
            return "范围前后颠倒了，请对调后再试。"
        }
    }
}

/// 高级筛选面板的原始输入（纯值类型，UI 控件只负责读写它）。
public struct AdvancedFilterValues: Sendable, Equatable {
    public var minSizeText: String
    public var maxSizeText: String
    public var useModifiedAfter: Bool
    public var modifiedAfter: Date
    public var useModifiedBefore: Bool
    public var modifiedBefore: Date
    public var caseSensitive: Bool

    public init(
        minSizeText: String = "",
        maxSizeText: String = "",
        useModifiedAfter: Bool = false,
        modifiedAfter: Date = Date(timeIntervalSince1970: 0),
        useModifiedBefore: Bool = false,
        modifiedBefore: Date = Date(timeIntervalSinceReferenceDate: 0),
        caseSensitive: Bool = false
    ) {
        self.minSizeText = minSizeText
        self.maxSizeText = maxSizeText
        self.useModifiedAfter = useModifiedAfter
        self.modifiedAfter = modifiedAfter
        self.useModifiedBefore = useModifiedBefore
        self.modifiedBefore = modifiedBefore
        self.caseSensitive = caseSensitive
    }

    public static let none = AdvancedFilterValues()
}

/// 高级筛选解析后的可查询条件。
public struct ResolvedFilters: Sendable, Equatable {
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var caseSensitive: Bool

    public init(
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        caseSensitive: Bool = false
    ) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.caseSensitive = caseSensitive
    }

    public static let none = ResolvedFilters()
}

public enum AdvancedFilterResolver {
    private static let unitMultipliers: [String: Int64] = [
        "": 1,
        "b": 1, "byte": 1, "bytes": 1, "字节": 1,
        "k": 1024, "kb": 1024, "kib": 1024, "千字节": 1024,
        "m": 1 << 20, "mb": 1 << 20, "mib": 1 << 20, "兆字节": 1 << 20,
        "g": 1 << 30, "gb": 1 << 30, "gib": 1 << 30, "吉字节": 1 << 30,
        "t": 1 << 40, "tb": 1 << 40, "tib": 1 << 40, "太字节": 1 << 40,
    ]

    private static let rangeSeparators = CharacterSet(charactersIn: "-~～—–至")

    /// 解析单个大小表达式：`""`、`"10mb"`、`">10mb"`、`">=1kb"`、`"<2gb"`、`"<=2gb"`。
    public static func parseSizeExpression(_ raw: String) throws -> (min: Int64?, max: Int64?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return (nil, nil) }

        // 区间："1mb-5mb" / "1mb ~ 5mb" / "1mb至5mb"
        let rangeParts = text.components(separatedBy: rangeSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if rangeParts.count == 2 {
            let lower = try parseSingle(rangeParts[0], bound: .lower)
            let upper = try parseSingle(rangeParts[1], bound: .upper)
            guard let low = lower.min, let high = upper.max else {
                throw FilterParseError.invalidSize(raw)
            }
            guard low <= high else { throw FilterParseError.minGreaterThanMax }
            return (low, high)
        }
        return try parseSingle(text, bound: .both)
    }

    private enum Bound { case lower, upper, both }

    private static func parseSingle(_ raw: String, bound: Bound) throws -> (min: Int64?, max: Int64?) {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var forced: Bound = bound
        var strict = false

        switch text.first {
        case ">":
            forced = .lower
            text.removeFirst()
            if text.first == "=" { text.removeFirst() } else { strict = true }
        case "<":
            forced = .upper
            text.removeFirst()
            if text.first == "=" { text.removeFirst() } else { strict = true }
        case "=":
            text.removeFirst()
        default:
            break
        }

        let (numberPart, unitPart) = splitNumberAndUnit(text)
        guard !numberPart.isEmpty,
              let value = Double(numberPart), value >= 0, value.isFinite,
              let multiplier = unitMultipliers[unitPart] else {
            throw FilterParseError.invalidSize(raw)
        }
        let scaled = (value * Double(multiplier)).rounded()
        guard scaled.isFinite, scaled >= 0, scaled < Double(Int64.max) else {
            throw FilterParseError.invalidSize(raw)
        }

        let bytes = Int64(scaled)
        switch forced {
        case .lower:
            return (strict ? bytes + 1 : bytes, nil)
        case .upper:
            return (nil, strict ? bytes - 1 : bytes)
        case .both:
            return (bytes, nil)
        }
    }

    private static func splitNumberAndUnit(_ text: String) -> (String, String) {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard ("0"..."9").contains(character) || character == "." else { break }
            index = text.index(after: index)
        }
        let number = String(text[text.startIndex..<index])
        let unit = String(text[index...]).trimmingCharacters(in: .whitespaces)
        return (number, unit)
    }

    /// 解析整组高级筛选；任一输入非法则整体失败，由 UI 显示错误而不是静默忽略。
    public static func resolve(_ values: AdvancedFilterValues) throws -> ResolvedFilters {
        let minExpr = try parseSizeExpression(values.minSizeText)
        let maxExpr = try parseSizeExpression(values.maxSizeText)
        let minSize = [minExpr.min, maxExpr.max == nil ? nil : maxExpr.min].compactMap { $0 }.max()
        let maxSize = [minExpr.max, maxExpr.max ?? maxExpr.min].compactMap { $0 }.min()
        if let minSize, let maxSize, minSize > maxSize {
            throw FilterParseError.minGreaterThanMax
        }

        var modifiedAfter: Date?
        var modifiedBefore: Date?
        if values.useModifiedAfter { modifiedAfter = values.modifiedAfter }
        if values.useModifiedBefore { modifiedBefore = values.modifiedBefore }
        if let a = modifiedAfter, let b = modifiedBefore, a > b {
            throw FilterParseError.minGreaterThanMax
        }

        return ResolvedFilters(
            minSize: minSize,
            maxSize: maxSize,
            modifiedAfter: modifiedAfter,
            modifiedBefore: modifiedBefore,
            caseSensitive: values.caseSensitive
        )
    }

    /// 把控件里的原始输入渲染回可编辑文本（用于恢复/初始化面板）。
    public static func sizeText(for bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        let units: [(String, Int64)] = [
            ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1024),
        ]
        for (name, multiplier) in units where bytes >= multiplier {
            let value = Double(bytes) / Double(multiplier)
            return "\(trimZeros(value))\(name)"
        }
        return "\(bytes)B"
    }

    private static func trimZeros(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        var text = "\(rounded)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }
}