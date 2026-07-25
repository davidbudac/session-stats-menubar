import AppKit

// Headless mode, for checking the numbers against `session_stats.py --rollup`:
//     SessionStatsBar --print [YYYY-MM-DD]
let args = CommandLine.arguments
if args.contains("--print") {
    let day = args.last.flatMap { Fmt.dayFormatter.date(from: $0) } ?? Date()
    let snap = Scanner().snapshot(for: day)
    print("Day        \(snap.day)")
    print("Sessions   \(snap.sessions.count) (\(snap.liveSessions.count) active)")
    func row(_ model: String, _ reqs: String, _ input: String, _ total: String, _ out: String) {
        func rpad(_ s: String, _ w: Int) -> String {
            s + String(repeating: " ", count: max(0, w - s.count))
        }
        func lpad(_ s: String, _ w: Int) -> String {
            String(repeating: " ", count: max(0, w - s.count)) + s
        }
        print(rpad(model, 18) + lpad(reqs, 10) + lpad(input, 10)
              + lpad(total, 15) + lpad(out, 11))
    }
    row("model", "reqs", "input", "total in", "output")
    for e in snap.ranked {
        row(Fmt.longModel(e.model), Fmt.full(e.totals.requests),
            Fmt.full(e.totals.inputUncached), Fmt.full(e.totals.totalInput),
            Fmt.full(e.totals.output))
    }
    let g = snap.grand
    row("TOTAL", Fmt.full(g.requests), Fmt.full(g.inputUncached),
        Fmt.full(g.totalInput), Fmt.full(g.output))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
