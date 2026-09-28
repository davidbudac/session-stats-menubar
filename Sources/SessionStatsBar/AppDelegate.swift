import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    /// The scanner does file I/O and is not thread-safe; it lives only here.
    private let scanQueue = DispatchQueue(label: "sessionstats.scan", qos: .utility)
    private let scanner = Scanner()
    private let subscriptions = Subscriptions()
    private var scanning = false
    /// A quota file changed while a refresh was already in flight.
    private var quotaStale = false
    private lazy var watcher = FileWatcher { [weak self] in self?.refresh(quotaOnly: true) }

    private var snapshot = DaySnapshot(day: Fmt.localDay(Date()))
    private var subs = SubscriptionSnapshot()
    /// Answers hover on each ring. Held strongly: tooltip owners aren't retained.
    private let ringTooltips = RingTooltipOwner()

    private static let refreshInterval: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SessionStatsMain"
        statusItem.button?.title = "…"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        ringTooltips.text = { [weak self] provider in
            guard let self else { return "" }
            return QuotaText.tooltip(provider, subs: self.subs, day: self.snapshot)
        }
        // Per-ring tooltip rects are in button coordinates, so they go stale
        // whenever the item resizes (a longer title elsewhere, a style switch).
        if let button = statusItem.button {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in self?.installRingTooltips() }
        }

        rebuildMenu()
        refresh()
        watcher.update()
        // Still needed with the watcher: resets and "as of" ages move with the
        // clock, and a source folder that appears later is picked up here.
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.watcher.update()
        }
        timer?.tolerance = 5
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
    }

    // MARK: - Refresh

    /// `quotaOnly` skips the transcript scan — what the file watcher wants,
    /// since only the quota sources are watched.
    private func refresh(quotaOnly: Bool = false) {
        guard !scanning else {   // a slow first pass must not pile up
            // What's in flight may have read the quota files before this change.
            if quotaOnly { quotaStale = true }
            return
        }
        scanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let snap = quotaOnly ? nil : self.scanner.snapshot()
            let subs = self.subscriptions.snapshot()
            DispatchQueue.main.async {
                self.scanning = false
                if let snap { self.snapshot = snap }
                self.subs = subs
                self.updateTitle()
                self.rebuildMenu()
                if self.quotaStale {
                    self.quotaStale = false
                    self.refresh(quotaOnly: true)
                }
            }
        }
    }

    // MARK: - Menu bar title

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let ranked = snapshot.ranked
        // Every path below sets its own tooltip; stale per-ring rects must not
        // outlive a switch to collapsed or text.
        button.removeAllToolTips()

        // Collapsed state shrinks this item to a single glyph rather than adding
        // a second status item to toggle visibility. A second item gets placed
        // wherever macOS decides — on a notched display that can be *behind the
        // notch*, leaving a control that exists and responds to clicks but is
        // invisible. Collapsing in place can't land somewhere unreachable, and
        // clicking still opens the menu, so the setting is always recoverable.
        if Settings.collapsed {
            button.image = nil
            button.imagePosition = .noImage   // .imageOnly would hide the title
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

        if Settings.menuBarStyle == .rings {
            showRings(on: button)
            return
        }
        button.image = nil
        button.imagePosition = .noImage

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
                    attributes: [.font: tag, .foregroundColor: NSColor.labelColor]))
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

    // MARK: - Rings

    private func showRings(on button: NSStatusBarButton) {
        let now = Date()
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = nil
        button.image = RingIcons.image(Provider.allCases.map { RingIcons.Face(subs.quota(for: $0), now: now) })
        button.imagePosition = .imageOnly
        installRingTooltips()
    }

    /// One tooltip rect per ring, so hovering Codex tells you about Codex. The
    /// button centres its image, so the rects are laid out from the same centre;
    /// the outer two stretch to the button's edges so there's no dead margin.
    private func installRingTooltips() {
        guard let button = statusItem.button, let image = button.image,
              !Settings.collapsed, Settings.menuBarStyle == .rings else { return }
        button.removeAllToolTips()
        let bounds = button.bounds
        let originX = bounds.minX + (bounds.width - image.size.width) / 2
        let slots = RingIcons.slots(count: Provider.allCases.count)
        for (index, slot) in slots.enumerated() {
            let minX = index == 0 ? bounds.minX : originX + slot.lowerBound - RingIcons.gap / 2
            let maxX = index == slots.count - 1
                ? bounds.maxX : originX + slot.upperBound + RingIcons.gap / 2
            button.addToolTip(NSRect(x: minX, y: bounds.minY, width: maxX - minX,
                                     height: bounds.height),
                              owner: ringTooltips, userData: RingTooltipOwner.userData(index))
        }
    }

    // MARK: - Dropdown

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func rebuildMenu() {
        menu.removeAllItems()

        addSubscriptions()
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

    /// One row per provider. A row that would run wider than the rest of the
    /// menu is split, windows going on indented rows beneath it.
    private func addSubscriptions() {
        let now = Date()
        menu.addItem(header("Subscriptions"))
        for provider in Provider.allCases {
            let quota = subs.quota(for: provider)
            let name = provider.title.padding(toLength: 8, withPad: " ", startingAt: 0)
            if provider == .cursor {
                menu.addItem(monospaced("\(name) not available locally"))
                continue
            }
            if let why = QuotaText.unavailable(quota, now: now) {
                menu.addItem(monospaced("\(name) \(why)"))
                continue
            }
            let windows = quota.windows.map { w -> String in
                var part = "\(w.name) \(Fmt.percent(100 - w.used(at: now)))% left"
                if w.hasReset(at: now) {
                    part += " · reset since"
                } else if let at = w.resetsAt {
                    part += " · resets \(Fmt.resets(at, now: now, short: true))"
                }
                return part
            }
            var extras: [String] = []
            if let plan = quota.plan { extras.append(plan) }
            // Age only earns space once it's old enough to change how you read it.
            if let at = quota.capturedAt, now.timeIntervalSince(at) > 15 * 60 {
                extras.append("as of \(Fmt.ago(at, now: now))")
            }
            let single = "\(name) " + windows.joined(separator: "   |   ")
                + extras.map { " · \($0)" }.joined()
            if single.count <= Self.maxSubscriptionRow {
                menu.addItem(monospaced(single))
            } else {
                menu.addItem(monospaced("\(name) " + (extras.isEmpty
                    ? "\(windows.count) windows" : extras.joined(separator: " · "))))
                for w in windows { menu.addItem(indented(w, by: 9)) }
            }
        }
        menu.addItem(.separator())
    }

    private static let maxSubscriptionRow = 72
    private static let maxLiveSessions = 4
    private static let maxAgentsPerSession = 6

    // MARK: - Settings submenu

    private func buildSettingsMenu() -> NSMenu {
        let sub = NSMenu()

        sub.addItem(header("Menu bar style"))
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(setMenuBarStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = Settings.menuBarStyle == style ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())

        // These only shape the token text, so the rings style leaves them out
        // rather than offering switches that visibly do nothing.
        if Settings.menuBarStyle == .text { addTextSettings(to: sub) }

        let collapse = NSMenuItem(title: "Collapse to ⋯",
                                  action: #selector(toggleCollapsed), keyEquivalent: "")
        collapse.target = self
        collapse.state = Settings.collapsed ? .on : .off
        collapse.toolTip = "Shrink the menu bar item to a single glyph. "
            + "Clicking it still opens this menu."
        sub.addItem(collapse)
        return sub
    }

    private func addTextSettings(to sub: NSMenu) {
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
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = MenuBarStyle(rawValue: raw) else { return }
        Settings.menuBarStyle = style
        applySettings()
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

    /// Read-only rows are built enabled, not disabled. AppKit renders a
    /// disabled item washed out no matter what `foregroundColor` you set, which
    /// made the whole readout barely legible against the action items below it.
    /// The menu turns off auto-enabling instead, so an item with no action stays
    /// full-contrast and simply does nothing when clicked.
    private func infoItem(_ title: String, font: NSFont, color: NSColor,
                          indent: Int = 0) -> NSMenuItem {
        let text = String(repeating: " ", count: indent) + title
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        infoItem(title, font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .secondaryLabelColor)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        infoItem(title, font: .systemFont(ofSize: 12), color: .labelColor)
    }

    private func indented(_ title: String, by columns: Int) -> NSMenuItem {
        infoItem(title, font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                 color: .secondaryLabelColor, indent: columns)
    }

    private func monospaced(_ title: String) -> NSMenuItem {
        infoItem(title, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                 color: .labelColor)
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
