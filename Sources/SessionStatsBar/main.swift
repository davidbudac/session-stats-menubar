import AppKit

// Headless mode, for checking the numbers against `session_stats.py --rollup`:
//     SessionStatsBar --print [YYYY-MM-DD]
//     SessionStatsBar --subscriptions          quota readings behind the rings
//     SessionStatsBar --render-icons out.png   the rings, drawn for inspection
let args = CommandLine.arguments
// `--settings` dumps what the app actually reads, which is the only reliable way
// to tell a preference that didn't apply from one that was never written.
if args.contains("--settings") {
    print("bundle id      \(Bundle.main.bundleIdentifier ?? "(none)")")
    print("menuBarStyle   \(Settings.menuBarStyle.rawValue)")
    print("metric         \(Settings.metric.rawValue)")
    print("maxModels      \(Settings.maxModels)")
    print("showLabels     \(Settings.showModelLabels)")
    print("collapsed      \(Settings.collapsed)")
    exit(0)
}

if args.contains("--subscriptions") {
    let now = Date()
    let reader = Subscriptions()
    let subs = reader.snapshot(for: now)
    func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
    for provider in Provider.allCases {
        let q = subs.quota(for: provider)
        print("\(provider.title)")
        switch provider {
        case .claude: print("  source     \(ClaudeQuotaReader.path.path)")
        case .codex:  print("  source     \(reader.codexFileCount) rollout(s) in the last 8 days")
        case .cursor: print("  source     none — Cursor keeps its quota server-side")
        }
        if let at = q.capturedAt {
            print("  captured   \(stamp(at))  (\(Fmt.ago(at, now: now)))"
                  + (q.isFresh(at: now) ? "" : "  STALE — ring shows unknown"))
        }
        if let plan = q.plan { print("  plan       \(plan)") }
        for w in q.windows {
            var line = "  window     \(w.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " captured \(Fmt.percent(w.usedPercent))% used"
                + " → now \(Fmt.percent(w.used(at: now)))% used, \(Fmt.percent(100 - w.used(at: now)))% left"
            if let r = w.resetsAt {
                line += w.hasReset(at: now) ? "  (reset at \(stamp(r)) — since capture)"
                    : "  resets \(stamp(r)) (\(Fmt.resets(r, now: now)))"
            }
            print(line)
        }
        let ring = q.remaining(at: now).map { "\(Fmt.percent(($0 * 1000).rounded() / 10))% left" } ?? "unknown"
        print("  ring       \(ring) · \(q.level(at: now))")
    }
    print("\nCodex today (\(Fmt.localDay(now)))")
    if subs.codexToday.isEmpty { print("  nothing recorded") }
    func row(_ c: [String]) {
        print(c[0].padding(toLength: 18, withPad: " ", startingAt: 0)
              + c.dropFirst().map { String(repeating: " ", count: max(0, 13 - $0.count)) + $0 }.joined())
    }
    if !subs.codexToday.isEmpty {
        row(["  model", "turns", "input", "cached", "output", "reasoning"])
        for (model, t) in subs.codexToday.sorted(by: { $0.value.total > $1.value.total }) {
            row(["  " + model, Fmt.full(t.events), Fmt.full(t.input), Fmt.full(t.cachedInput),
                 Fmt.full(t.output), Fmt.full(t.reasoningOutput)])
        }
    }
    exit(0)
}

if let flag = args.firstIndex(of: "--render-icons") {
    let path = args.indices.contains(flag + 1) ? args[flag + 1] : "rings.png"
    guard RingIcons.writePreview(to: path, real: Subscriptions().snapshot()) else {
        FileHandle.standardError.write(Data("couldn't write \(path)\n".utf8))
        exit(1)
    }
    print("wrote \(path)")
    exit(0)
}

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
