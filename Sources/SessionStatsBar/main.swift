import AppKit

// Headless mode, for checking the numbers against `session_stats.py --rollup`:
//     SessionStatsBar --print [YYYY-MM-DD]
let args = CommandLine.arguments
if args.contains("--print") {
    let day = args.last.flatMap { Fmt.dayFormatter.date(from: $0) } ?? Date()
    let snap = Scanner().snapshot(for: day)
    print("Day        \(snap.day)")
    print("Sessions   \(snap.sessions.count) (\(snap.liveSessions.count) active)")
    func row(_ cells: [String]) {
        func rpad(_ s: String, _ w: Int) -> String {
            s + String(repeating: " ", count: max(0, w - s.count))
        }
        func lpad(_ s: String, _ w: Int) -> String {
            String(repeating: " ", count: max(0, w - s.count)) + s
        }
        print(rpad(cells[0], 18) + cells.dropFirst().map { lpad($0, 14) }.joined())
    }
    row(["model", "reqs", "input", "cache wr", "cache rd", "output", "cost"])
    func cells(_ name: String, _ t: Totals, _ cost: Double) -> [String] {
        [name, Fmt.full(t.requests), Fmt.full(t.inputUncached),
         Fmt.full(t.cacheWrite), Fmt.full(t.cacheRead), Fmt.full(t.output),
         Pricing.money(cost)]
    }
    for e in snap.ranked {
        row(cells(Fmt.longModel(e.model), e.totals, e.cost))
        for part in Pricing.breakdown(e.totals, model: e.model, on: snap.scannedAt)
        where part.cost >= 0.005 {
            print("    \(part.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + Pricing.money(part.cost))
        }
    }
    row(cells("TOTAL", snap.grand, snap.totalCost))

    print("\nsessions")
    for s in snap.sessions.sorted(by: { $0.cost > $1.cost }) {
        print("  \(s.isLive ? "●" : " ") \(s.project.padding(toLength: 26, withPad: " ", startingAt: 0))"
              + "\(Pricing.money(s.cost))  \(Fmt.compact(s.totals.output)) out"
              + "  \(s.agents.count) agents")
        for a in s.agents {
            print("      \(a.isLive ? "●" : "·") "
                  + "\(a.label.padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + "\(Pricing.money(a.cost))  \(Fmt.compact(a.totals.output)) out"
                  + "  \(a.primaryModel.map(Fmt.shortModel) ?? "?")")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
