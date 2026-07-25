import AppKit

/// Regenerates the skill's standalone HTML dashboard and opens it in the
/// default browser. The app never renders the report itself — `visualize.py`
/// already does, and keeping one implementation means one thing to keep true.
enum Dashboard {
    static func locateScript() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "visualizePath") {
            candidates.append(override)
        }
        if let root = env["CLAUDE_PLUGIN_ROOT"] {
            candidates.append("\(root)/skills/session-stats/visualize.py")
        }
        candidates += [
            "\(home)/.claude/skills/session-stats/visualize.py",
            "\(home)/.claude/plugins/session-stats/skills/session-stats/visualize.py",
        ]
        // Any plugin checkout that happens to carry the skill.
        let pluginRoot = "\(home)/.claude/plugins"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: pluginRoot) {
            candidates += entries.map {
                "\(pluginRoot)/\($0)/skills/session-stats/visualize.py"
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Returns nil on success, or a message describing what went wrong.
    static func open() -> String? {
        guard let script = locateScript() else {
            return "Couldn't find visualize.py. Install the session-stats skill under "
                + "~/.claude/skills/session-stats/, or set a path with:\n\n"
                + "defaults write \(Bundle.main.bundleIdentifier ?? "com.davidbudac.SessionStatsBar") "
                + "visualizePath /path/to/visualize.py"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", script, "--open"]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return "Couldn't run python3: \(error.localizedDescription)"
        }
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return nil }
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return "visualize.py exited with status \(task.terminationStatus).\n\n"
            + err.split(separator: "\n").suffix(6).joined(separator: "\n")
    }
}
