import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    /// The scanner does file I/O and is not thread-safe; it lives only here.
    private let scanQueue = DispatchQueue(label: "sessionstats.scan", qos: .utility)
    private let scanner = Scanner()
    private var scanning = false

    private var snapshot = DaySnapshot(day: Fmt.localDay(Date()))

    private static let refreshInterval: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SessionStatsMain"
        statusItem.button?.title = "…"
        menu.delegate = self
        statusItem.menu = menu

        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 5
    }

    // MARK: - Refresh

    private func refresh() {
        guard !scanning else { return }   // a slow first pass must not pile up
        scanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.scanner.snapshot()
            DispatchQueue.main.async {
                self.scanning = false
                self.snapshot = snap
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Menu bar title

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let ranked = snapshot.ranked

        // Collapsed state shrinks this item to a single glyph rather than adding
        // a second status item to toggle visibility. A second item gets placed
        // wherever macOS decides — on a notched display that can be *behind the
        // notch*, leaving a control that exists and responds to clicks but is
        // invisible. Collapsing in place can't land somewhere unreachable, and
        // clicking still opens the menu, so the setting is always recoverable.
        if Settings.collapsed {
            button.attributedTitle = NSAttributedString(
                string: "⋯",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = ranked.isEmpty
                ? "Session Stats — nothing recorded today"
                : "Today: ~\(Pricing.money(snapshot.totalCost)) · "
                    + "\(Fmt.full(snapshot.grand.output)) output — click for detail"
            return
        }

        guard !ranked.isEmpty else {
            button.attributedTitle = NSAttributedString(
                string: "—",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = "No Claude Code tokens recorded today"
            return
        }

        let tag = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let dim = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        // A busy day can touch five models; the menu bar is not that wide.
        // The dropdown always shows every one of them.
        let cap = Settings.maxModels
        let shown = cap > 0 ? Array(ranked.prefix(cap)) : ranked
        let hidden = ranked.count - shown.count
        let metric = Settings.metric

        let title = NSMutableAttributedString()
        for (index, entry) in shown.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .font: dim, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if Settings.showModelLabels {
                title.append(NSAttributedString(
                    string: Fmt.shortModel(entry.model) + " ",
                    attributes: [.font: tag, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let parts = metric.render(entry.totals, cost: entry.cost)
            title.append(NSAttributedString(string: parts.primary, attributes: [
                .font: value, .foregroundColor: NSColor.labelColor]))
            if let secondary = parts.secondary {
                title.append(NSAttributedString(string: secondary, attributes: [
                    .font: dim, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
        }
        if hidden > 0 {
            title.append(NSAttributedString(string: " +\(hidden)", attributes: [
                .font: dim, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        button.attributedTitle = title

        let grand = snapshot.grand
        button.toolTip = "Today: ~\(Pricing.money(snapshot.totalCost)) — "
            + "\(Fmt.full(grand.output)) output, \(Fmt.full(grand.totalInput)) input, "
            + "across \(snapshot.sessions.count) session(s)"
    }

    // MARK: - Dropdown

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(header("Today · \(snapshot.day)"))

        let ranked = snapshot.ranked
        if ranked.isEmpty {
            menu.addItem(disabled("Nothing recorded yet today"))
        } else {
            let width = max(ranked.map { Fmt.longModel($0.model).count }.max() ?? 0, 10)
            for entry in ranked {
                let name = Fmt.longModel(entry.model)
                    .padding(toLength: width, withPad: " ", startingAt: 0)
                menu.addItem(monospaced("\(name)  \(pad(Pricing.money(entry.cost), 8))"
                    + " · \(pad(Fmt.compact(entry.totals.output), 6)) out"
                    + " · \(pad(Fmt.compact(entry.totals.totalInput), 6)) in"))
                // Where the money actually went — output is rarely the top line.
                let parts = Pricing.breakdown(entry.totals, model: entry.model,
                                              on: snapshot.scannedAt)
                    .filter { $0.cost >= 0.005 }
                    .map { "\($0.label) \(Pricing.money($0.cost))" }
                if !parts.isEmpty {
                    menu.addItem(indented(parts.joined(separator: " · "), by: width + 2))
                }
            }
            menu.addItem(.separator())

            let grand = snapshot.grand
            menu.addItem(monospaced("Total".padding(toLength: width, withPad: " ", startingAt: 0)
                + "  \(pad(Pricing.money(snapshot.totalCost), 8))"
                + " · \(pad(Fmt.compact(grand.output), 6)) out"
                + " · \(pad(Fmt.compact(grand.totalInput), 6)) in"))
            let hitRate = grand.totalInput > 0
                ? Double(grand.cacheRead) / Double(grand.totalInput) * 100 : 0
            menu.addItem(disabled(String(format: "Cache hit rate  %.1f%%  ·  %d requests",
                                         hitRate, grand.requests)))
            if ranked.contains(where: { !Pricing.rate(for: $0.model).known }) {
                menu.addItem(disabled("Some models have no price on file — Opus rates assumed"))
            }
            var sessionLine = "\(snapshot.sessions.count) session"
                + (snapshot.sessions.count == 1 ? "" : "s")
            let agentCount = snapshot.sessions.reduce(0) { $0 + $1.agents.count }
            if agentCount > 0 {
                sessionLine += " · \(agentCount) subagent" + (agentCount == 1 ? "" : "s")
            }
            menu.addItem(disabled(sessionLine))
            addActiveSessions()
        }

        menu.addItem(.separator())
        menu.addItem(action("Open Dashboard", #selector(openDashboard), key: "d"))
        menu.addItem(action("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.submenu = buildSettingsMenu()
        menu.addItem(settings)

        let login = action("Open at Login", #selector(toggleLaunchAtLogin), key: "")
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quit Session Stats", #selector(quit), key: "q"))
    }

    /// Sessions that wrote to their transcript in the last few minutes, each with
    /// the subagents it spawned today. Bounded so a fan-out heavy day can't grow
    /// the menu past the screen.
    private func addActiveSessions() {
        let live = snapshot.liveSessions
        guard !live.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(header("Running now"))

        for session in live.prefix(Self.maxLiveSessions) {
            let name = session.project.padding(toLength: 22, withPad: " ", startingAt: 0)
            var line = "\(name) \(pad(Pricing.money(session.cost), 8))"
                + " · \(pad(Fmt.compact(session.totals.output), 6)) out"
            if let model = session.primaryModel { line += " · \(Fmt.shortModel(model))" }
            menu.addItem(monospaced(line))

            if session.agents.isEmpty {
                menu.addItem(indented("no subagents", by: 2))
                continue
            }
            let agentTotal = session.agentCost
            let share = session.cost > 0 ? agentTotal / session.cost * 100 : 0
            menu.addItem(indented(String(
                format: "%d subagents · %@ (%.0f%% of session)",
                session.agents.count, Pricing.money(agentTotal), share), by: 2))

            for agent in session.agents.prefix(Self.maxAgentsPerSession) {
                let mark = agent.isLive ? "●" : "·"
                let label = agent.label.padding(toLength: 18, withPad: " ", startingAt: 0)
                var line = "\(mark) \(label) \(pad(Pricing.money(agent.cost), 8))"
                    + " · \(pad(Fmt.compact(agent.totals.output), 6)) out"
                if let model = agent.primaryModel { line += " · \(Fmt.shortModel(model))" }
                menu.addItem(indented(line, by: 3))
            }
            let hidden = session.agents.count - min(session.agents.count, Self.maxAgentsPerSession)
            if hidden > 0 { menu.addItem(indented("+\(hidden) more", by: 5)) }
        }
        let hidden = live.count - min(live.count, Self.maxLiveSessions)
        if hidden > 0 { menu.addItem(indented("+\(hidden) more session(s)", by: 2)) }
    }

    private static let maxLiveSessions = 4
    private static let maxAgentsPerSession = 6

    // MARK: - Settings submenu

    private func buildSettingsMenu() -> NSMenu {
        let sub = NSMenu()

        sub.addItem(header("Menu bar shows"))
        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: metric.title, action: #selector(setMetric(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = Settings.metric == metric ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(header("Models in menu bar"))
        for count in [1, 2, 3, 0] {
            let item = NSMenuItem(title: count == 0 ? "All" : "\(count)",
                                  action: #selector(setMaxModels(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = Settings.maxModels == count ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let labels = NSMenuItem(title: "Show model labels",
                                action: #selector(toggleModelLabels), keyEquivalent: "")
        labels.target = self
        labels.state = Settings.showModelLabels ? .on : .off
        sub.addItem(labels)

        let collapse = NSMenuItem(title: "Collapse to ⋯",
                                  action: #selector(toggleCollapsed), keyEquivalent: "")
        collapse.target = self
        collapse.state = Settings.collapsed ? .on : .off
        collapse.toolTip = "Shrink the menu bar item to a single glyph. "
            + "Clicking it still opens this menu."
        sub.addItem(collapse)
        return sub
    }

    @objc private func setMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = MenuBarMetric(rawValue: raw) else { return }
        Settings.metric = metric
        applySettings()
    }

    @objc private func setMaxModels(_ sender: NSMenuItem) {
        Settings.maxModels = sender.tag
        applySettings()
    }

    @objc private func toggleModelLabels() {
        Settings.showModelLabels.toggle()
        applySettings()
    }

    @objc private func toggleCollapsed() {
        Settings.collapsed.toggle()
        applySettings()
    }

    private func applySettings() {
        updateTitle()
        rebuildMenu()
    }

    private func pad(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - s.count)) + s
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    private func indented(_ title: String, by columns: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: String(repeating: " ", count: columns) + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        return item
    }

    private func monospaced(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor])
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow() { refresh() }

    @objc private func openDashboard() {
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = Dashboard.open()
            guard let problem else { return }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn't open the dashboard"
                alert.informativeText = problem
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Launch at login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nThis needs the app to live in a stable location — "
                + "move it to /Applications and try again."
            alert.alertStyle = .warning
            alert.runModal()
        }
        rebuildMenu()
    }
}
