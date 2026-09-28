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

    /// "just now", "12m ago", "3h ago", "2d ago" — how stale a quota reading is.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60:        return "just now"
        case ..<3600:      return "\(Int(s / 60))m ago"
        case ..<(48 * 3600): return "\(Int(s / 3600))h ago"
        default:           return "\(Int(s / 86400))d ago"
        }
    }

    /// "2h 14m", "45m" — a short span, rounded up so it never reads "0m" early.
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// When a quota window resets. Within a day a countdown is what you want
    /// ("in 2h 14m"); past that, the weekday reads faster ("Thu 09:12").
    /// `short` drops "in" and the time of day, for the dropdown's tight rows.
    static func resets(_ date: Date, now: Date = Date(), short: Bool = false) -> String {
        let s = date.timeIntervalSince(now)
        if s < 24 * 3600 { return (short ? "" : "in ") + span(s) }
        return (short ? weekday : weekdayTime).string(from: date)
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "12.5" for fractional percentages, "13" otherwise.
    static func percent(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
