import Foundation

/// Parsed form of `SearchQuery.text`.
///
/// Grammar (whitespace separated, `"..."` groups a token containing spaces):
/// * bare word            -> required substring (AND with every other bare word)
/// * `-word`              -> excluded substring
/// * `path:word`          -> substring restricted to the relative path
/// * `ext:pdf`            -> extension filter, comma separated
/// * `size:>10mb`         -> size filter, `<`, `<=`, `>`, `>=`, `=` and bare values
/// * `date:2026-01-01..2026-12-31` -> modified-date range, also `<`/`>` and single dates
struct ParsedQuery: Sendable {
    var includeTerms: [String] = []
    var nameTerms: [String] = []
    var excludedPathTerms: [String] = []
    var excludedNameTerms: [String] = []
    var excludeTerms: [String] = []
    var pathTerms: [String] = []
    var extensions: Set<String> = []
    var sizePredicate: SizePredicate?
    var datePredicate: DatePredicate?
}

enum SizePredicate: Sendable {
    case range(minInclusive: Int64?, maxInclusive: Int64?)

    func matches(_ size: Int64) -> Bool {
        switch self {
        case .range(let low, let high):
            if let low, size < low { return false }
            if let high, size > high { return false }
            return true
        }
    }
}

enum DatePredicate: Sendable {
    case range(after: Date?, before: Date?)

    func matches(_ date: Date) -> Bool {
        switch self {
        case .range(let after, let before):
            if let after, date < after { return false }
            if let before, date > before { return false }
            return true
        }
    }
}

enum QueryParser {
    /// Splits on whitespace, honouring double quotes for tokens with spaces.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasContent = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                hasContent = true
                continue
            }
            if !inQuotes && character.isWhitespace {
                if hasContent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
                continue
            }
            current.append(character)
            hasContent = true
        }
        if hasContent || !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Parses `text`. When `caseSensitive` is true, terms keep their letter case and
    /// are only NFC-normalized — folding them would make a case-sensitive query
    /// unable to match anything.
    static func parse(_ text: String, caseSensitive: Bool = false) -> ParsedQuery {
        var parsed = ParsedQuery()
        var rawExtensions: [String] = []

        for token in tokenize(text) {
            guard !token.isEmpty else { continue }
            if token.hasPrefix("-path:") {
                addTerm(&parsed.excludedPathTerms, String(token.dropFirst(6)), caseSensitive: caseSensitive)
                continue
            }
            if token.hasPrefix("-name:") {
                addTerm(&parsed.excludedNameTerms, String(token.dropFirst(6)), caseSensitive: caseSensitive)
                continue
            }
            if let (field, value) = splitField(token) {
                switch field {
                case "path":
                    addTerm(&parsed.pathTerms, value, caseSensitive: caseSensitive)
                case "name":
                    addTerm(&parsed.nameTerms, value, caseSensitive: caseSensitive)
                case "ext", "extension":
                    rawExtensions.append(contentsOf: value.split(separator: ",").map(String.init))
                case "size":
                    if let bounds = parseSize(value) {
                        parsed.sizePredicate = .range(
                            minInclusive: [parsed.sizePredicate?.minValue, bounds.min].compactMap { $0 }.max(),
                            maxInclusive: [parsed.sizePredicate?.maxValue, bounds.max].compactMap { $0 }.min()
                        )
                    }
                case "date", "modified":
                    if let bounds = parseDateRange(value) {
                        parsed.datePredicate = .range(after: [parsed.datePredicate?.afterValue, bounds.after].compactMap { $0 }.max(), before: [parsed.datePredicate?.beforeValue, bounds.before].compactMap { $0 }.min())
                    }
                default:
                    // An unknown `foo:` prefix is *not* a filter — macOS filenames may
                    // legitimately contain a colon, so keep the whole token literal.
                    addTerm(&parsed.includeTerms, token, caseSensitive: caseSensitive)
                }
                continue
            }

            if token.hasPrefix("-"), token.count > 1 {
                addTerm(&parsed.excludeTerms, String(token.dropFirst()), caseSensitive: caseSensitive)
            } else {
                addTerm(&parsed.includeTerms, token, caseSensitive: caseSensitive)
            }
        }

        for value in rawExtensions {
            if let normalized = IndexText.normalizeExtensionFilter(value) {
                parsed.extensions.insert(normalized)
            }
        }
        return parsed
    }

    private static func addTerm(_ terms: inout [String], _ value: String, caseSensitive: Bool) {
        let key = caseSensitive ? IndexText.canonicalKey(value) : IndexText.foldedKey(value)
        guard !key.isEmpty, !terms.contains(key) else { return }
        terms.append(key)
    }

    /// Splits `path:foo` into field and value. An empty value is returned rather than
    /// rejected, so that a bare `ext:` / `size:` is treated as "no filter given"
    /// instead of degrading into the literal search term `ext:`.
    private static func splitField(_ token: String) -> (field: String, value: String)? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let field = String(token[token.startIndex..<colon]).lowercased()
        guard !field.isEmpty else { return nil }
        let value = String(token[token.index(after: colon)...])
        return (field, value)
    }

    // MARK: - size

    static let sizeUnits: [(suffix: String, multiplier: Int64)] = [
        ("kib", 1024), ("mib", 1024 * 1024), ("gib", 1024 * 1024 * 1024),
        ("tib", 1024 * 1024 * 1024 * 1024),
        ("kb", 1000), ("mb", 1000 * 1000), ("gb", 1000 * 1000 * 1000),
        ("tb", 1000 * 1000 * 1000 * 1000),
        ("k", 1024), ("m", 1024 * 1024), ("g", 1024 * 1024 * 1024),
        ("t", 1024 * 1024 * 1024 * 1024),
        ("b", 1),
    ]

    /// `">10mb"` -> `(min: nil, max: 10_000_000)`; `"1kb..2kb"` -> both bounds.
    /// Returns nil for unusable input, which leaves the filter unset rather than
    /// silently filtering everything out.
    static func parseSize(_ value: String) -> (min: Int64?, max: Int64?)? {
        if let separator = value.range(of: "..") {
            let low = parseMagnitude(String(value[value.startIndex..<separator.lowerBound]))
            let high = parseMagnitude(String(value[separator.upperBound...]))
            guard low != nil || high != nil else { return nil }
            return (low, high)
        }
        var token = value.lowercased()
        var op = ""
        while let first = token.first, "<>=".contains(first) {
            op.append(first)
            token.removeFirst()
        }
        guard let magnitude = parseMagnitude(token) else { return nil }
        switch op {
        case ">": return magnitude < Int64.max ? (magnitude + 1, nil) : nil
        case ">=": return (magnitude, nil)
        case "<": return (nil, magnitude - 1)
        case "<=": return (nil, magnitude)
        default: return (magnitude, magnitude)
        }
    }

    private static func parseMagnitude(_ token: String) -> Int64? {
        var number = ""
        var suffix = ""
        for character in token {
            if character.isNumber || character == "." || character == "-" {
                number.append(character)
            } else if !character.isWhitespace {
                suffix.append(character)
            }
        }
        guard let value = Double(number) else { return nil }
        guard suffix.isEmpty || sizeUnits.contains(where: { $0.suffix == suffix }) else { return nil }
        let multiplier = sizeUnits.first { $0.suffix == suffix }?.multiplier ?? 1
        let scaled = (value * Double(multiplier)).rounded()
        guard scaled.isFinite, scaled >= 0, scaled < Double(Int64.max) else { return nil }
        return Int64(scaled)
    }

    // MARK: - date

    /// `"2026-01-01..2026-12-31"` / `">2026-01-01"` / `"2026-01-01"`.
    /// Range ends are inclusive of the whole day.
    static func parseDateRange(_ value: String) -> (after: Date?, before: Date?)? {
        var token = value
        var op = ""
        while let first = token.first, "<>=".contains(first) {
            op.append(first)
            token.removeFirst()
        }
        if let separator = token.range(of: "..") {
            let lower = parseDate(String(token[token.startIndex..<separator.lowerBound]))?.startOfDay
            let upper = parseDate(String(token[separator.upperBound...]))?.endOfDay
            guard lower != nil || upper != nil else { return nil }
            return (lower, upper)
        }
        guard let date = parseDate(token) else { return nil }
        switch op {
        case ">", ">=": return (date.startOfDay, nil)
        case "<", "<=": return (nil, date.endOfDay)
        default: return (date.startOfDay, date.endOfDay)
        }
    }

    static func parseDate(_ token: String) -> DateComponents? {
        let normalized = token.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        return components
    }
}

extension DateComponents {
    var startOfDay: Date? {
        var copy = self
        copy.hour = copy.hour ?? 0
        copy.minute = copy.minute ?? 0
        copy.second = copy.second ?? 0
        copy.nanosecond = copy.nanosecond ?? 0
        return copy.date
    }

    var endOfDay: Date? {
        guard let start = startOfDay else { return nil }
        return (calendar ?? Calendar(identifier: .gregorian)).date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
    }
}