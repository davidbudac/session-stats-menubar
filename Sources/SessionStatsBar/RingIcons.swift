import AppKit

/// The menu bar's ring readout: one ring per subscription showing how much
/// quota is *left* — a full ring is untouched — with that percentage inside.
/// Providers are told apart by colour.
///
/// Everything is drawn in code — rings with `NSBezierPath`, the number as text.
/// `build.sh` ships only the binary, so there are no asset files to lean on.
enum RingIcons {
    static let diameter: CGFloat = 18
    static let gap: CGFloat = 5
    static let lineWidth: CGFloat = 2

    /// What one icon needs to draw itself. Decoupled from `ProviderQuota` so the
    /// `--render-icons` check can draw states the real data isn't in.
    struct Face {
        var provider: Provider
        /// Remaining fraction of the weekly window (see `ringWindow`); nil = unknown, no arc.
        var remaining: Double?
        var level: ProviderQuota.Level

        init(provider: Provider, remaining: Double?) {
            self.provider = provider
            self.remaining = remaining
            switch remaining {
            case nil: level = .unknown
            case let r? where r <= ProviderQuota.criticalThreshold: level = .critical
            case let r? where r <= ProviderQuota.lowThreshold: level = .low
            default: level = .ok
            }
        }

        init(_ quota: ProviderQuota, now: Date) {
            self.init(provider: quota.provider, remaining: quota.remaining(at: now))
        }
    }

    static func size(count: Int) -> NSSize {
        NSSize(width: CGFloat(count) * diameter + CGFloat(max(0, count - 1)) * gap,
               height: diameter)
    }

    /// Horizontal extent of each icon inside the image, left to right.
    static func slots(count: Int) -> [ClosedRange<CGFloat>] {
        (0..<count).map {
            let x = CGFloat($0) * (diameter + gap)
            return x...(x + diameter)
        }
    }

    /// Not a template image — the rings are coloured — so light/dark has to be
    /// handled here. The drawing handler runs at draw time under the status
    /// button's appearance, which is when dynamic colours like `labelColor`
    /// resolve correctly; `.never` caching makes sure it runs again when the
    /// menu bar flips between light and dark.
    static func image(_ faces: [Face]) -> NSImage {
        let image = NSImage(size: size(count: faces.count), flipped: false) { _ in
            for (face, slot) in zip(faces, slots(count: faces.count)) {
                draw(face, in: NSRect(x: slot.lowerBound, y: 0, width: diameter, height: diameter))
            }
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }

    // MARK: - Drawing

    private static func draw(_ face: Face, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (diameter - lineWidth) / 2
        let badge = face.level == .low || face.level == .critical
        let badgeCenter = NSPoint(x: center.x + radius * 0.74, y: center.y + radius * 0.74)

        // Drawn into a transparency layer so the gap around the badge can be
        // cut out of the ring itself rather than out of the menu bar behind it.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(face.level == .unknown ? 0.14 : 0.2).setStroke()
        track.stroke()

        if let left = face.remaining, left > 0 {
            // 12 o'clock, clockwise — angles run counter-clockwise in AppKit.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(left, 1)), clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = left >= 1 ? .butt : .round
            (face.level == .critical ? NSColor.systemRed : tint(face.provider)).setStroke()
            arc.stroke()
        }

        drawPercent(face, center: center, ctx: ctx)

        if badge {
            ctx.setBlendMode(.clear)
            NSBezierPath(ovalIn: circle(badgeCenter, 3.9)).fill()
            ctx.setBlendMode(.normal)
        }
        ctx.endTransparencyLayer()

        if badge {
            amber.setFill()
            NSBezierPath(ovalIn: circle(badgeCenter, 2.7)).fill()
        }
    }

    private static func circle(_ c: NSPoint, _ r: CGFloat) -> NSRect {
        NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    /// Percent left, digits only — there's no room for a "%" in a 14pt hole.
    /// Whole numbers, so it matches the tooltip's "% left" unless that shows a
    /// fractional reading (e.g. "12.5"). Unknown is a dash.
    private static func drawPercent(_ face: Face, center c: NSPoint, ctx: CGContext) {
        let text: String
        let color: NSColor
        if let left = face.remaining {
            text = String(Int(min(max((left * 100).rounded(), 0), 100)))
            color = face.level == .critical ? .systemRed : tint(face.provider)
        } else {
            text = "–"
            color = NSColor.labelColor.withAlphaComponent(0.45)
        }
        // Three digits only happen at 100; they get a smaller, tighter setting.
        let wide = text.count > 2
        let size: CGFloat = wide ? 6.4 : 8
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .kern: wide ? -0.35 : 0,
        ])

        // Centre on the ink, not the line box: digits sit on the baseline and
        // rise to the cap height. Set with Core Text at an explicit baseline,
        // snapped to device pixels so the digits don't straddle rows at 1x.
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + (wide ? 0.35 : 0)
        let ink = text == "–" ? font.xHeight : font.capHeight
        let scale = max(ctx.userSpaceToDeviceSpaceTransform.a.magnitude, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: snap(c.x - width / 2), y: snap(c.y - ink / 2))
        CTLineDraw(line, ctx)
    }

    // MARK: - Colours

    /// Resolved at draw time. Indigo is lifted a step on a dark menu bar, where
    /// the brand shade sinks into the background.
    static func tint(_ provider: Provider) -> NSColor {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        case .cursor: return .labelColor
        }
    }

    private static let claude = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    private static let codex = NSColor(name: "codexIndigo") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x81 / 255, green: 0x8C / 255, blue: 0xF8 / 255, alpha: 1)
            : NSColor(srgbRed: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255, alpha: 1)
    }
    private static let amber = NSColor(srgbRed: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1)
}

// MARK: - Tooltips

/// Supplies per-icon hover text for the status button. Text is built when the
/// tooltip is about to show, not when the rect is registered, so "resets in"
/// and "as of" are current rather than up to 30 seconds old.
final class RingTooltipOwner: NSObject, NSViewToolTipOwner {
    var text: (Provider) -> String = { $0.title }

    /// Rects are keyed by index through `userData`; no pointers are dereferenced.
    static func userData(_ index: Int) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: index + 1)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard Provider.allCases.indices.contains(index) else { return "" }
        return text(Provider.allCases[index])
    }
}

/// The words behind each ring, shared by the tooltip and `--subscriptions`.
enum QuotaText {
    /// "5h      13% used · 87% left · resets in 2h 14m"
    static func windowLines(_ quota: ProviderQuota, now: Date) -> [String] {
        let width = max(quota.windows.map(\.name.count).max() ?? 0, 6)
        return quota.windows.map { w in
            let name = w.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let used = w.used(at: now)
            var line = "\(name)  \(Fmt.percent(used))% used · \(Fmt.percent(100 - used))% left"
            if w.hasReset(at: now) {
                line += " · reset since"
            } else if let at = w.resetsAt {
                line += " · resets \(Fmt.resets(at, now: now))"
            }
            return line
        }
    }

    /// Why a provider has no ring, or nil if it has one.
    static func unavailable(_ quota: ProviderQuota, now: Date) -> String? {
        if quota.provider == .cursor { return "quota isn't available locally" }
        guard let at = quota.capturedAt, !quota.windows.isEmpty else {
            return quota.provider == .claude
                ? "no data yet — needs the statusline snippet (see README)"
                : "no data yet — run Codex once"
        }
        if !quota.isFresh(at: now) { return "last reading \(Fmt.ago(at, now: now)) — too old to trust" }
        return nil
    }

    static func tooltip(_ provider: Provider, subs: SubscriptionSnapshot,
                        day: DaySnapshot, now: Date = Date()) -> String {
        let quota = subs.quota(for: provider)
        var lines: [String] = []
        if let why = unavailable(quota, now: now) {
            lines.append("\(provider.title) — \(why)")
        } else {
            var head = provider.title
            if let plan = quota.plan { head += " (\(plan))" }
            if let at = quota.capturedAt { head += " — as of \(Fmt.ago(at, now: now))" }
            lines.append(head)
            lines += windowLines(quota, now: now)
        }

        switch provider {
        case .claude:
            let ranked = day.ranked
            guard !ranked.isEmpty else { break }
            lines.append("")
            lines.append("Today")
            let width = max(ranked.map { Fmt.longModel($0.model).count }.max() ?? 0, 5)
            func row(_ name: String, _ cost: Double, _ t: Totals) -> String {
                name.padding(toLength: width, withPad: " ", startingAt: 0)
                    + "   \(Pricing.money(cost)) · \(Fmt.compact(t.output)) out"
                    + " · \(Fmt.compact(t.totalInput)) in"
            }
            for e in ranked { lines.append(row(Fmt.longModel(e.model), e.cost, e.totals)) }
            if ranked.count > 1 { lines.append(row("Total", day.totalCost, day.grand)) }
        case .codex:
            let models = subs.codexToday.sorted { $0.value.total > $1.value.total }
            guard !models.isEmpty else { break }
            lines.append("")
            lines.append("Today")
            let width = max(models.map(\.key.count).max() ?? 0, 5)
            for (model, t) in models {
                lines.append(model.padding(toLength: width, withPad: " ", startingAt: 0)
                    + "   \(Fmt.compact(t.output)) out · \(Fmt.compact(t.input)) in"
                    + " (\(Fmt.compact(t.cachedInput)) cached)")
            }
            if models.count > 1 {
                let sum = models.reduce(into: CodexTotals()) { $0 += $1.value }
                lines.append("Total".padding(toLength: width, withPad: " ", startingAt: 0)
                    + "   \(Fmt.compact(sum.output)) out · \(Fmt.compact(sum.input)) in")
            }
        case .cursor:
            break
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Preview

extension RingIcons {
    /// Backs `--render-icons`: the menu bar image on light and dark bars, as
    /// drawn natively at 4x and as it lands on 1x and 2x pixels (enlarged
    /// without smoothing, so blur and stray half-pixels show). Real data first,
    /// then sample states the real data may not be in.
    static func writePreview(to path: String, real subs: SubscriptionSnapshot) -> Bool {
        let now = Date()
        func faces(_ claude: Double?, _ codex: Double?) -> [Face] {
            [Face(provider: .claude, remaining: claude), Face(provider: .codex, remaining: codex),
             Face(provider: .cursor, remaining: nil)]
        }
        let rows: [(String, [Face])] = [
            ("real data", Provider.allCases.map { Face(subs.quota(for: $0), now: now) }),
            ("88% · 99%", faces(0.88, 0.99)),
            ("50% · 30%", faces(0.5, 0.3)),
            ("15% · 3%", faces(0.15, 0.03)),
            ("100% · unknown", faces(1, nil)),
            ("unknown", faces(nil, nil)),
        ]
        let bars: [(NSAppearance.Name, NSColor)] = [
            (.aqua, NSColor(white: 0.93, alpha: 1)), (.darkAqua, NSColor(white: 0.16, alpha: 1)),
        ]
        let scales: [CGFloat] = [4, 1, 2]   // native, then pixel-true 1x and 2x
        let label: CGFloat = 96
        let panel = NSSize(width: size(count: 3).width + 16, height: 24)
        let canvas = NSSize(width: label + panel.width * CGFloat(bars.count * scales.count),
                            height: panel.height * CGFloat(rows.count + 1))

        func bitmap(_ size: NSSize, scale: CGFloat, _ body: () -> Void) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            body()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func drawPanel(_ faces: [Face], bar: (NSAppearance.Name, NSColor), in rect: NSRect) {
            bar.1.setFill()
            rect.fill()
            let img = image(faces)
            let origin = NSPoint(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2)
            NSAppearance(named: bar.0)?.performAsCurrentDrawingAppearance {
                img.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }

        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                   .foregroundColor: NSColor.black]
        let rep = bitmap(canvas, scale: 4) {
            NSColor.white.setFill()
            NSRect(origin: .zero, size: canvas).fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            for (s, scale) in scales.enumerated() {
                for b in bars.indices {
                    let x = label + panel.width * CGFloat(s * bars.count + b)
                    let title = "\(Int(scale))x \(b == 0 ? "light" : "dark")"
                    title.draw(at: NSPoint(x: x + 4, y: canvas.height - 14), withAttributes: text)
                }
            }
            for (r, row) in rows.enumerated() {
                let y = canvas.height - panel.height * CGFloat(r + 2)
                row.0.draw(at: NSPoint(x: 4, y: y + 7), withAttributes: text)
                for (s, scale) in scales.enumerated() {
                    for (b, bar) in bars.enumerated() {
                        let rect = NSRect(x: label + panel.width * CGFloat(s * bars.count + b),
                                          y: y, width: panel.width, height: panel.height)
                        if scale == 4 {
                            drawPanel(row.1, bar: bar, in: rect)
                        } else if let small = bitmap(panel, scale: scale, {
                            drawPanel(row.1, bar: bar, in: NSRect(origin: .zero, size: panel))
                        }) {
                            small.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                                       respectFlipped: false, hints: nil)
                        }
                    }
                }
            }
        }
        guard let png = rep?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
