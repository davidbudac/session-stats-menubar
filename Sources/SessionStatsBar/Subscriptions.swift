import Foundation

/// The coding subscriptions shown as rings in the menu bar.
enum Provider: String, CaseIterable, Sendable {
    case claude, codex, cursor

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// One rate-limit window as its tool last reported it — "5h", "weekly", "7d opus".
struct QuotaWindow: Sendable {
    var name: String
    /// Percent used when the snapshot was taken, 0–100.
    var usedPercent: Double
    var resetsAt: Date?

    /// A snapshot is only as fresh as the last time its tool ran. If the window
    /// has rolled over since, whatever was used then no longer counts.
    func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    func used(at now: Date) -> Double {
        hasReset(at: now) ? 0 : min(max(usedPercent, 0), 100)
    }

    /// Fraction still available, 0...1.
    func remaining(at now: Date) -> Double { 1 - used(at: now) / 100 }
}

/// Everything known about one subscription's quota.
struct ProviderQuota: Sendable {
    enum Level { case unknown, ok, low, critical }

    var provider: Provider
    var windows: [QuotaWindow] = []
    /// When the tool wrote the numbers — not when we read them.
    var capturedAt: Date?
    var plan: String?

    /// Past this, a snapshot says more about when the tool last ran than about
    /// the quota. A weekly window has certainly turned over by then.
    static let maxAge: TimeInterval = 8 * 24 * 3600
    static let lowThreshold = 0.20
    static let criticalThreshold = 0.05

    func isFresh(at now: Date) -> Bool {
        guard let capturedAt, !windows.isEmpty else { return false }
        return now.timeIntervalSince(capturedAt) <= Self.maxAge
    }

    /// The window with the least left — the one that will stop you first.
    func mostConstrained(at now: Date) -> QuotaWindow? {
        guard isFresh(at: now) else { return nil }
        return windows.min { $0.remaining(at: now) < $1.remaining(at: now) }
    }

    /// Ring fill. Nil means "don't know", which is drawn differently from empty.
    func remaining(at now: Date) -> Double? {
        mostConstrained(at: now)?.remaining(at: now)
    }

    func level(at now: Date) -> Level {
        guard let left = remaining(at: now) else { return .unknown }
        if left <= Self.criticalThreshold { return .critical }
        if left <= Self.lowThreshold { return .low }
        return .ok
    }
}

/// Codex tokens for one model. Codex's `input_tokens` already *includes* the
/// cached part, unlike Claude's transcripts where the two are disjoint.
struct CodexTotals: Sendable {
    var events = 0
    var input = 0
    var cachedInput = 0
    var output = 0
    var reasoningOutput = 0

    var total: Int { input + output }

    static func += (a: inout CodexTotals, b: CodexTotals) {
        a.events += b.events
        a.input += b.input
        a.cachedInput += b.cachedInput
        a.output += b.output
        a.reasoningOutput += b.reasoningOutput
    }
}

/// What the rings and the Subscriptions section need, gathered in one pass.
struct SubscriptionSnapshot: Sendable {
    var claude = ProviderQuota(provider: .claude)
    var codex = ProviderQuota(provider: .codex)
    /// Cursor keeps its quota server-side; there is nothing local to read.
    var cursor = ProviderQuota(provider: .cursor)
    /// Today's Codex tokens by model. There's no Codex price table, so no dollars.
    var codexToday: [String: CodexTotals] = [:]
    var scannedAt = Date()

    func quota(for provider: Provider) -> ProviderQuota {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        case .cursor: return cursor
        }
    }
}

/// Gathers every provider's quota. Owns the Codex reader's per-file state, so
/// like `Scanner` it is not thread-safe and lives on the scan queue.
final class Subscriptions {
    private let codex = CodexReader()

    /// Rollouts the last pass looked at, for `--subscriptions`.
    var codexFileCount: Int { codex.fileCount }

    func snapshot(for now: Date = Date()) -> SubscriptionSnapshot {
        var snap = SubscriptionSnapshot()
        snap.claude = ClaudeQuotaReader.read()
        let result = codex.read(now: now)
        snap.codex = result.quota
        snap.codexToday = result.today
        snap.scannedAt = now
        return snap
    }
}

// MARK: - Claude

/// Claude Code has no quota file of its own. Its statusline command is handed
/// the session's `rate_limits` on stdin, and a few lines in the user's
/// statusline script snapshot them to `session-stats/rate-limits.json` (see the
/// README). So this is exactly as fresh as the last statusline render.
enum ClaudeQuotaReader {
    static var path: URL {
        let env = ProcessInfo.processInfo.environment
        let claude = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return claude.appendingPathComponent("session-stats/rate-limits.json")
    }

    /// Known windows first, in the order you'd read them; anything new after.
    private static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    static func read() -> ProviderQuota {
        var quota = ProviderQuota(provider: .claude)
        guard let data = FileManager.default.contents(atPath: path.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return quota }

        quota.capturedAt = date(obj["captured_at"])
        // Tolerant on purpose: the payload grows new windows (and differently
        // shaped entries like a spend limit) without notice. Anything that
        // carries a percentage is a window; everything else is skipped.
        let limits = obj["rate_limits"] as? [String: Any] ?? [:]
        let keys = limits.keys.sorted {
            let a = order.firstIndex(of: $0) ?? order.count
            let b = order.firstIndex(of: $1) ?? order.count
            return a == b ? $0 < $1 : a < b
        }
        for key in keys {
            guard let entry = limits[key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            quota.windows.append(QuotaWindow(name: label(key), usedPercent: used,
                                             resetsAt: date(entry["resets_at"])))
        }
        return quota
    }

    /// "five_hour" → "5h", "seven_day_opus" → "7d opus".
    static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "five_hour", with: "5h")
            .replacingOccurrences(of: "seven_day", with: "7d")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Epoch seconds as a number, or an ISO 8601 string.
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = value as? String {
            if let n = Double(s) { return Date(timeIntervalSince1970: n) }
            return Fmt.parseTimestamp(s)
        }
        return nil
    }
}

// MARK: - Codex

/// Reads Codex CLI's session rollouts, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Every `token_count` event carries the account's `rate_limits` as the server
/// reported them on that turn, so the newest such event across all rollouts is
/// the freshest quota reading there is. Like Claude's, it's only as fresh as the
/// last time Codex ran.
///
/// Only credentials-free session logs are read — never `auth.json` or anything
/// else under `~/.codex`.
final class CodexReader {
    /// A rate-limit reading and when Codex recorded it.
    private struct Reading {
        var at: Date
        var windows: [QuotaWindow]
        var plan: String?
    }

    private struct FileState {
        var cursor = LineCursor()
        /// `token_count` events don't name a model; the latest `turn_context`
        /// in the same file does.
        var model: String?
        /// Codex sometimes repeats a `token_count` verbatim. A repeat has the
        /// same running total, so only a change in it marks a new turn.
        var lastTotal: Int?
        var latest: Reading?
        var byDay: [String: [String: CodexTotals]] = [:]
    }

    private var files: [String: FileState] = [:]
    private let root = CodexReader.sessionsRoot

    /// `$CODEX_HOME/sessions`, defaulting to `~/.codex/sessions`.
    static var sessionsRoot: URL {
        let env = ProcessInfo.processInfo.environment
        let home = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    private static let tokenCountMarker = Array(#""type":"token_count""#.utf8)
    private static let turnContextMarker = Array(#""type":"turn_context""#.utf8)

    /// Scanned files, for `--subscriptions`.
    private(set) var fileCount = 0

    func read(now: Date) -> (quota: ProviderQuota, today: [String: CodexTotals]) {
        let cutoff = now.addingTimeInterval(-ProviderQuota.maxAge)
        let recent = discover(modifiedSince: cutoff, now: now)
        files = files.filter { recent.contains($0.key) }
        fileCount = recent.count

        let keepFrom = Fmt.localDay(Calendar.current.date(byAdding: .day, value: -1,
                                                           to: now) ?? now)
        for path in recent {
            var state = files[path] ?? FileState()
            ingest(path: path, into: &state)
            state.byDay = state.byDay.filter { $0.key >= keepFrom }
            files[path] = state
        }

        var quota = ProviderQuota(provider: .codex)
        if let newest = files.values.compactMap(\.latest).max(by: { $0.at < $1.at }) {
            quota.capturedAt = newest.at
            quota.windows = newest.windows
            quota.plan = newest.plan
        }
        let today = Fmt.localDay(now)
        var byModel: [String: CodexTotals] = [:]
        for state in files.values {
            for (model, totals) in state.byDay[today] ?? [:] { byModel[model, default: .init()] += totals }
        }
        return (quota, byModel)
    }

    // MARK: Discovery

    /// Walks the dated layout one level at a time instead of recursing through
    /// every rollout ever written. Day folders inside the window are listed in
    /// full; older ones are only stat'ed, because a resumed session keeps
    /// appending to the rollout in the folder of the day it *started*.
    private func discover(modifiedSince cutoff: Date, now: Date) -> [String] {
        let fm = FileManager.default
        let cutoffDay = Fmt.localDay(cutoff)
        // Anything older than this is not worth even a stat.
        let staleDay = Fmt.localDay(now.addingTimeInterval(-90 * 24 * 3600))
        func dirs(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { $0.allSatisfy(\.isNumber) }
        }

        var out: [String] = []
        for year in dirs(root) {
            let yearURL = root.appendingPathComponent(year)
            for month in dirs(yearURL) {
                let monthURL = yearURL.appendingPathComponent(month)
                for day in dirs(monthURL) {
                    let stamp = "\(year)-\(month)-\(day)"
                    guard stamp >= staleDay else { continue }
                    let dayURL = monthURL.appendingPathComponent(day)
                    let names = (try? fm.contentsOfDirectory(atPath: dayURL.path)) ?? []
                    for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                        let path = dayURL.appendingPathComponent(name).path
                        if stamp >= cutoffDay || Self.modified(path, since: cutoff) {
                            out.append(path)
                        }
                    }
                }
            }
        }
        return out
    }

    private static func modified(_ path: String, since cutoff: Date) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return Double(info.st_mtimespec.tv_sec) >= cutoff.timeIntervalSince1970
    }

    // MARK: Ingest

    private func ingest(path: String, into state: inout FileState) {
        guard let size = LineReader.size(of: path) else { return }
        if size < state.cursor.offset { state = FileState() }   // rewritten — start over
        guard size > state.cursor.offset else { return }

        var cursor = state.cursor
        LineReader.readAppended(path: path, cursor: &cursor) { line in
            // Most bytes are tool output and messages; only two kinds of line
            // matter, and a raw byte scan rules the rest out without parsing.
            let isTokens = LineReader.contains(line, Self.tokenCountMarker)
            guard isTokens || LineReader.contains(line, Self.turnContextMarker) else { return }
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { return }
                if obj["type"] as? String == "turn_context" {
                    if let model = payload["model"] as? String { state.model = model }
                } else if payload["type"] as? String == "token_count" {
                    Self.handleTokenCount(obj, payload, into: &state)
                }
            }
        }
        state.cursor = cursor
    }

    private static func handleTokenCount(_ obj: [String: Any], _ payload: [String: Any],
                                         into state: inout FileState) {
        guard let tsString = obj["timestamp"] as? String,
              let ts = Fmt.parseTimestamp(tsString) else { return }

        if let limits = payload["rate_limits"] as? [String: Any] {
            let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
                guard let w = limits[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let minutes = (w["window_minutes"] as? NSNumber)?.intValue
                return QuotaWindow(name: minutes.map(windowLabel) ?? key, usedPercent: used,
                                   resetsAt: ClaudeQuotaReader.date(w["resets_at"]))
            }
            if !windows.isEmpty, ts >= (state.latest?.at ?? .distantPast) {
                state.latest = Reading(at: ts, windows: windows,
                                       plan: limits["plan_type"] as? String)
            }
        }

        // `info` is null on the event that only reports rate limits.
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return }
        let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int
        if let total, total == state.lastTotal { return }
        state.lastTotal = total

        var t = CodexTotals()
        t.events = 1
        t.input = last["input_tokens"] as? Int ?? 0
        t.cachedInput = last["cached_input_tokens"] as? Int ?? 0
        t.output = last["output_tokens"] as? Int ?? 0
        t.reasoningOutput = last["reasoning_output_tokens"] as? Int ?? 0
        state.byDay[Fmt.localDay(ts), default: [:]][state.model ?? "unknown", default: .init()] += t
    }

    /// 300 → "5h", 10080 → "weekly", 4320 → "3d", 720 → "12h".
    static func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 10080: return "weekly"
        case let m where m > 0 && m % 1440 == 0: return "\(m / 1440)d"
        case let m where m > 0 && m % 60 == 0: return "\(m / 60)h"
        default: return "\(minutes)m"
        }
    }
}
