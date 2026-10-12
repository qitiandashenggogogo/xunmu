import Foundation

/// Pure helpers shared by the store and the engine. They deliberately never mutate
/// the caller's strings: `relativePath` / `name` keep their original bytes and are
/// only ever *copied* into a normalized matching key.
enum IndexText {
    /// Parent of a relative path. `"a/b.txt"` -> `"a"`, `"a"` -> `""`,
    /// `""` -> `""`. Used so a directory's direct children can be found by exact
    /// string equality instead of an ambiguous prefix match.
    ///
    /// The result is canonicalized (no leading/trailing separators) so a scanner
    /// that reports `/a/b.txt` and one that reports `a/b.txt` land on the same key.
    static func parentPath(of relativePath: String) -> String {
        let canonical = canonicalRelativePath(relativePath)
        guard let slash = canonical.lastIndex(of: "/") else { return "" }
        return String(canonical[canonical.startIndex..<slash])
    }

    /// Canonical form of a relative path used for scope comparisons: leading and
    /// trailing separators removed. The root directory normalizes to `""`.
    static func canonicalRelativePath(_ path: String) -> String {
        // Fast path: already canonical, so hand back the very same instance.
        // `String` is a value type, but returning it costs one retain, not a copy —
        // and this runs once per indexed entry at engine build time.
        if !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/") { return path }
        var result = Substring(path)
        while result.hasPrefix("/") { result = result.dropFirst() }
        while result.hasSuffix("/"), !result.isEmpty { result = result.dropLast() }
        return String(result)
    }

    /// Canonical (NFC) form only: normalizes decomposed vs precomposed characters
    /// while leaving letter case untouched. This is the matching key when the
    /// query asked for case sensitivity.
    static func canonicalKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    /// Matching key for a name or path: canonical equivalence first so a
    /// decomposed `é` matches a precomposed one, then case folding.
    ///
    /// Deliberately **not** width-insensitive: full-width and half-width digits are
    /// genuinely different filename characters, and collapsing them would make
    /// `Ａ１.txt` match a query for `a1`. Use `caseInsensitive` folding only.
    static func foldedKey(_ value: String) -> String {
        let canonical = canonicalKey(value)
        // Fast path: pure ASCII. `folding(options: .caseInsensitive)` walks the
        // full Unicode case-folding tables and always allocates, which at one call
        // per name and per path is ~2M allocations for a million-entry index.
        // `lowercased()` has an ASCII fast path and returns `self` when the text is
        // already lower-case, so typical filenames cost nothing at all.
        if canonical.utf8.allSatisfy({ $0 < 0x80 }) { return canonical.lowercased() }
        return canonical.folding(options: [.caseInsensitive], locale: nil)
    }

    /// File extension without the dot, lowercase. Leading-dot names such as
    /// `.gitignore` have no extension.
    static func lowercaseExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let suffix = name[name.index(after: dot)...]
        if suffix.isEmpty { return nil }
        // A dot at position 0 means a hidden file, not an extension.
        guard dot != name.startIndex else { return nil }
        return suffix.lowercased()
    }

    /// Normalizes a user supplied extension filter (`PDF`, `.pdf` -> `pdf`).
    static func normalizeExtensionFilter(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Escapes a user path for use with SQLite `LIKE ... ESCAPE '\'`.
    static func likeEscape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}