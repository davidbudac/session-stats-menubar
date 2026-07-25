import Foundation

/// Turns token counts into dollars.
///
/// Worth stating plainly, because it's counterintuitive: **output tokens are not
/// the cost driver for Claude Code.** On a representative day here, output was
/// 13% of spend and the prompt cache was 87% — cache reads are cheap per token
/// (0.1x) but enormous in volume, and cache writes cost double the input rate on
/// a 1-hour TTL. Uncached input rounds to zero. That's why the menu bar shows
/// money rather than any single token count: no one count proxies for price.
///
/// The skill this app accompanies deliberately reports tokens and no prices, on
/// the grounds that a baked-in price table goes stale. That's a real cost of
/// doing this — so every rate is overridable (see `rate(for:)`) and the table
/// carries the date it was accurate.
enum Pricing {
    /// Dollars per million tokens. Accurate as of 2026-07-25.
    struct Rate {
        var input: Double
        var output: Double
    }

    /// Cache multipliers, applied to the model's *input* rate.
    private static let cacheReadMultiplier = 0.1
    private static let cacheWrite5mMultiplier = 1.25
    private static let cacheWrite1hMultiplier = 2.0

    /// Matched by longest prefix, so `claude-opus-5[1m]` resolves to `opus-5`.
    private static let table: [(prefix: String, rate: Rate)] = [
        ("opus-5",     Rate(input: 5,  output: 25)),
        ("opus-4-8",   Rate(input: 5,  output: 25)),
        ("opus-4-7",   Rate(input: 5,  output: 25)),
        ("opus-4-6",   Rate(input: 5,  output: 25)),
        ("opus-4-5",   Rate(input: 5,  output: 25)),
        ("fable-5",    Rate(input: 10, output: 50)),
        ("mythos-5",   Rate(input: 10, output: 50)),
        ("sonnet-5",   Rate(input: 3,  output: 15)),   // see introductory rate below
        ("sonnet-4-6", Rate(input: 3,  output: 15)),
        ("sonnet-4-5", Rate(input: 3,  output: 15)),
        ("haiku-4-5",  Rate(input: 1,  output: 5)),
    ]

    /// Sonnet 5 launched at a reduced rate through 2026-08-31.
    private static let sonnet5Intro = Rate(input: 2, output: 10)
    private static let sonnet5IntroEnds = Fmt.dayFormatter.date(from: "2026-09-01")!

    /// A model with no table entry is priced at the Opus tier and flagged, so an
    /// unrecognised model shows a plausible-but-marked number instead of $0.
    static let fallback = Rate(input: 5, output: 25)

    static func rate(for model: String, on date: Date = Date()) -> (rate: Rate, known: Bool) {
        let id = Fmt.longModel(model).lowercased()
        // A `maxTokens`-style override: defaults write ... rate_opus-5 -array 5 25
        if let hit = table.first(where: { id.hasPrefix($0.prefix) }) {
            if let custom = override(for: hit.prefix) { return (custom, true) }
            if hit.prefix == "sonnet-5", date < sonnet5IntroEnds {
                return (sonnet5Intro, true)
            }
            return (hit.rate, true)
        }
        return (fallback, false)
    }

    private static func override(for prefix: String) -> Rate? {
        guard let pair = UserDefaults.standard.array(forKey: "rate_\(prefix)") as? [NSNumber],
              pair.count == 2 else { return nil }
        return Rate(input: pair[0].doubleValue, output: pair[1].doubleValue)
    }

    /// What each component of a token bundle costs, biggest first.
    static func breakdown(_ t: Totals, model: String, on date: Date = Date())
        -> [(label: String, cost: Double)] {
        let r = rate(for: model, on: date).rate
        let m = 1_000_000.0
        return [
            ("cache read", Double(t.cacheRead) / m * r.input * cacheReadMultiplier),
            ("cache write", Double(t.cacheWrite1h) / m * r.input * cacheWrite1hMultiplier
                + Double(t.cacheWrite5m) / m * r.input * cacheWrite5mMultiplier),
            ("output", Double(t.output) / m * r.output),
            ("input", Double(t.inputUncached) / m * r.input),
        ].sorted { $0.cost > $1.cost }
    }

    static func cost(_ t: Totals, model: String, on date: Date = Date()) -> Double {
        breakdown(t, model: model, on: date).reduce(0) { $0 + $1.cost }
    }

    /// "$0.42", "$5.78", "$28.0", "$134"
    static func money(_ v: Double) -> String {
        switch abs(v) {
        case 0..<10:   return String(format: "$%.2f", v)
        case 10..<100: return String(format: "$%.1f", v)
        default:       return String(format: "$%.0f", v)
        }
    }
}
