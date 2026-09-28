import Foundation

/// What sits in the menu bar: quota rings per subscription, or the original
/// per-model token readout.
enum MenuBarStyle: String, CaseIterable {
    case rings
    case text

    var title: String {
        switch self {
        case .rings: return "Rings"
        case .text:  return "Token text"
        }
    }
}

/// What the menu bar prints for each model, in the `text` style.
enum MenuBarMetric: String, CaseIterable {
    case output
    case outputAndInput
    case totalInput
    case cost
    case requests

    var title: String {
        switch self {
        case .output:         return "Output tokens"
        case .outputAndInput: return "Output / total input"
        case .totalInput:     return "Total input"
        case .cost:           return "Estimated cost"
        case .requests:       return "Requests"
        }
    }

    /// The second element is rendered dimmer and smaller — it's context, not the
    /// number you're meant to read at a glance.
    func render(_ totals: Totals, cost: Double) -> (primary: String, secondary: String?) {
        switch self {
        case .output:         return (Fmt.compact(totals.output), nil)
        case .outputAndInput: return (Fmt.compact(totals.output),
                                      "/" + Fmt.compact(totals.totalInput))
        case .totalInput:     return (Fmt.compact(totals.totalInput), nil)
        case .cost:           return (Pricing.money(cost), nil)
        case .requests:       return ("\(totals.requests)", " req")
        }
    }
}

/// User preferences, all backed by `UserDefaults` so they survive relaunch and
/// stay scriptable with `defaults write`.
enum Settings {
    private static let store = UserDefaults.standard

    static var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: store.string(forKey: "menuBarStyle") ?? "") ?? .rings }
        set { store.set(newValue.rawValue, forKey: "menuBarStyle") }
    }

    static var metric: MenuBarMetric {
        get { MenuBarMetric(rawValue: store.string(forKey: "metric") ?? "") ?? .output }
        set { store.set(newValue.rawValue, forKey: "metric") }
    }

    /// Models printed before collapsing the rest into "+N". 0 means all.
    static var maxModels: Int {
        get { store.object(forKey: "maxModels") as? Int ?? 3 }
        set { store.set(newValue, forKey: "maxModels") }
    }

    static var showModelLabels: Bool {
        get { store.object(forKey: "showModelLabels") as? Bool ?? true }
        set { store.set(newValue, forKey: "showModelLabels") }
    }

    /// Shrinks the menu bar item to a single glyph. Not a second status item:
    /// see the note in `updateTitle()`.
    static var collapsed: Bool {
        get { store.bool(forKey: "collapsed") }
        set { store.set(newValue, forKey: "collapsed") }
    }
}
