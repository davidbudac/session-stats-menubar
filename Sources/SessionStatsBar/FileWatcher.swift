import CoreServices
import Foundation

/// Watches the two quota sources so the rings move within about a second of a
/// tool writing new numbers, instead of on the next poll.
///
/// One FSEvents stream covers both. It watches directories, not files: the
/// Claude snapshot is replaced by rename, which would orphan a watch on the
/// file itself, and Codex keeps adding day folders. A source whose folder
/// doesn't exist yet is left out, and `update()` — called on every poll —
/// picks it up once it appears.
///
/// Main thread only: the stream delivers on the main queue.
final class FileWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var pending = false
    private var lastFire = Date.distantPast

    /// FSEvents' own coalescing window.
    private static let latency: CFTimeInterval = 0.3
    /// Codex appends many lines per turn; one refresh a second is plenty.
    private static let minInterval: TimeInterval = 1

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    private var claudeDir: String { Self.real(ClaudeQuotaReader.path.deletingLastPathComponent()) }
    private var claudeFile: String { claudeDir + "/" + ClaudeQuotaReader.path.lastPathComponent }
    private var codexRoot: String { Self.real(CodexReader.sessionsRoot) }

    /// FSEvents reports `realpath(3)` paths, so that's what they're compared
    /// against. Foundation's `resolvingSymlinksInPath` won't do: it turns
    /// `/private/tmp` into `/tmp`, the opposite direction.
    private static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// (Re)creates the stream if the set of folders that exist has changed.
    func update() {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let roots = [claudeDir, codexRoot].filter {
            fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        guard roots != watched || (stream == nil && !roots.isEmpty) else { return }
        stop()
        watched = roots
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(list, flags: UnsafeBufferPointer(start: flags, count: count))
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, options)
        else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: Events

    private func handle(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        // The Claude folder also holds the busy `sessions.jsonl`; only the
        // snapshot counts there. Everything under Codex's sessions does.
        let claude = claudeFile
        let codex = codexRoot + "/"
        let overflow = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged)
        let relevant = zip(paths, flags).contains { path, flag in
            path == claude || path.hasPrefix(codex) || flag & overflow != 0
        }
        if relevant { schedule() }
    }

    /// Leading edge after FSEvents' latency, then at most once per `minInterval`.
    private func schedule() {
        guard !pending else { return }
        pending = true
        let wait = max(0, lastFire.addingTimeInterval(Self.minInterval).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.lastFire = Date()
            self.onChange()
        }
    }
}
