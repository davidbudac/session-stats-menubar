import Foundation

enum Fmt {
    /// "O5", "O48", "F5", "S5", "H45" — the menu bar is too narrow for
    /// "claude-opus-4-8". Derived generically so a model I've never seen still
    /// gets a sensible tag instead of a crash or a raw id.
    static func shortModel(_ id: String) -> String {
        var s = id.lowercased()
        // strip context-window suffixes like "[1m]" and vendor prefixes
        if let b = s.firstIndex(of: "[") { s = String(s[s.startIndex..<b]) }
        for prefix in ["us.anthropic.", "anthropic.", "claude-", "claude."] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        let families = ["opus": "O", "sonnet": "S", "haiku": "H", "fable": "F"]
        var tokens = s.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" })
            .map(String.init)
        // drop release-date tokens (8 digits) and trailing "v1:0" style ids
        tokens = tokens.filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }

        guard let famIdx = tokens.firstIndex(where: { families[$0] != nil }),
              let letter = families[tokens[famIdx]] else {
            let alnum = s.filter(\.isLetter)
            return String(alnum.prefix(3)).uppercased()
        }
        let digits = tokens.enumerated()
            .filter { $0.offset != famIdx && $0.element.allSatisfy(\.isNumber) }
            .map(\.element)
            .joined()
        return letter + digits
    }

    /// Human name for the dropdown: "opus-4.8" rather than the full id.
    static func longModel(_ id: String) -> String {
        var s = id
        for prefix in ["us.anthropic.", "anthropic.", "claude-"] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        return s
    }

    /// 152 → "152", 4_712 → "4.7k", 152_345 → "152k", 47_912_345 → "47.9M"
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(n) {
        case 0..<1_000:             return "\(n)"
        case 1_000..<10_000:        return trim(v / 1_000, 1) + "k"
        case 10_000..<1_000_000:    return trim(v / 1_000, 0) + "k"
        case 1_000_000..<100_000_000: return trim(v / 1_000_000, 1) + "M"
        case 100_000_000..<1_000_000_000: return trim(v / 1_000_000, 0) + "M"
        default:                    return trim(v / 1_000_000_000, 1) + "B"
        }
    }

    private static func trim(_ v: Double, _ places: Int) -> String {
        var s = String(format: "%.\(places)f", v)
        if s.contains("."), s.hasSuffix("0") { s.removeLast(2) }  // 4.0k → 4k
        return s
    }

    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func full(_ n: Int) -> String {
        grouped.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func localDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Transcript timestamps are ISO 8601 UTC with fractional seconds
    /// ("2026-07-25T07:31:43.738Z"), but the log's `ended_at` sometimes has none.
    static func parseTimestamp(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
