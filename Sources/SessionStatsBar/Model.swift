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

/// One subagent spawned by a session. `label` prefers the name the parent gave
/// it, falling back to the agent type — "Explore" is more use than "a8295dd65".
struct AgentSnapshot: Sendable {
    var id: String
    var label: String
    var byModel: [String: Totals] = [:]
    var lastActivity: Date?
    var isLive = false

    var totals: Totals { byModel.values.reduce(Totals(), +) }
    var cost: Double {
        byModel.reduce(0) { $0 + Pricing.cost($1.value, model: $1.key) }
    }
    /// The model that actually served this agent, for display.
    var primaryModel: String? {
        byModel.max { $0.value.output < $1.value.output }?.key
    }
}

/// One Claude Code session: its main thread plus any subagents it spawned.
struct SessionSnapshot: Sendable {
    var id: String
    var project: String
    var byModel: [String: Totals] = [:]   // main thread only
    var agents: [AgentSnapshot] = []
    var lastActivity: Date?
    var isLive = false

    var mainTotals: Totals { byModel.values.reduce(Totals(), +) }
    var mainCost: Double {
        byModel.reduce(0) { $0 + Pricing.cost($1.value, model: $1.key) }
    }
    var agentCost: Double { agents.reduce(0) { $0 + $1.cost } }
    var cost: Double { mainCost + agentCost }
    var totals: Totals { agents.reduce(mainTotals) { $0 + $1.totals } }
    var primaryModel: String? {
        byModel.max { $0.value.output < $1.value.output }?.key
    }
}

/// Everything the UI needs for one day.
struct DaySnapshot: Sendable {
    var day: String                       // local calendar day, yyyy-MM-dd
    var byModel: [String: Totals] = [:]   // keyed by full model id
    var sessions: [SessionSnapshot] = []
    var scannedAt = Date()

    var liveSessions: [SessionSnapshot] {
        sessions.filter(\.isLive).sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

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
