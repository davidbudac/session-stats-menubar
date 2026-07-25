import Foundation

/// Token counters for one model on one day. Field names mirror the
/// `session-stats` skill so the numbers line up with `--rollup`.
struct Totals: Sendable {
    var requests = 0
    var inputUncached = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0

    /// What the skill calls "Total input": uncached + cache write + cache read.
    var totalInput: Int { inputUncached + cacheWrite + cacheRead }

    static func + (a: Totals, b: Totals) -> Totals {
        Totals(requests: a.requests + b.requests,
               inputUncached: a.inputUncached + b.inputUncached,
               cacheWrite: a.cacheWrite + b.cacheWrite,
               cacheRead: a.cacheRead + b.cacheRead,
               output: a.output + b.output)
    }

    static func += (a: inout Totals, b: Totals) { a = a + b }
}

/// Everything the UI needs for one day.
struct DaySnapshot: Sendable {
    var day: String                       // local calendar day, yyyy-MM-dd
    var byModel: [String: Totals] = [:]   // keyed by full model id
    var sessions: Set<String> = []        // distinct session ids seen
    var liveSessions: Set<String> = []    // touched in the last few minutes
    var scannedAt = Date()

    var grand: Totals { byModel.values.reduce(Totals(), +) }

    /// Models with output today, biggest first — the menu bar order.
    var ranked: [(model: String, totals: Totals)] {
        byModel
            .filter { $0.value.output > 0 || $0.value.requests > 0 }
            .sorted {
                $0.value.output == $1.value.output
                    ? $0.key < $1.key
                    : $0.value.output > $1.value.output
            }
            .map { (model: $0.key, totals: $0.value) }
    }
}
