import Foundation

/// Token counters for one model on one day. Field names mirror the
/// `session-stats` skill so the numbers line up with `--rollup`.
struct Totals: Sendable {
    var requests = 0
    var inputUncached = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0
    /// The 1-hour-TTL slice of `cacheWrite`. Billed at 2x input rather than the
    /// 5-minute tier's 1.25x, so pricing needs the split, not just the total.
    var cacheWrite1h = 0

    /// The remainder of `cacheWrite`. When a transcript carries no TTL split we
    /// land here, which matches the API default of a 5-minute cache.
    var cacheWrite5m: Int { max(0, cacheWrite - cacheWrite1h) }

    /// What the skill calls "Total input": uncached + cache write + cache read.
    var totalInput: Int { inputUncached + cacheWrite + cacheRead }

    static func + (a: Totals, b: Totals) -> Totals {
        Totals(requests: a.requests + b.requests,
               inputUncached: a.inputUncached + b.inputUncached,
               cacheWrite: a.cacheWrite + b.cacheWrite,
               cacheRead: a.cacheRead + b.cacheRead,
               output: a.output + b.output,
               cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
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

    /// Models used today, most expensive first — the menu bar order.
    var ranked: [(model: String, totals: Totals, cost: Double)] {
        byModel
            .filter { $0.value.requests > 0 }
            .map { (model: $0.key, totals: $0.value,
                    cost: Pricing.cost($0.value, model: $0.key, on: scannedAt)) }
            .sorted { $0.cost == $1.cost ? $0.model < $1.model : $0.cost > $1.cost }
    }

    var totalCost: Double { ranked.reduce(0) { $0 + $1.cost } }
}
