import Foundation

/// Reads Claude Code's own transcripts to answer one question: how many tokens,
/// per model, today?
///
/// Why transcripts and not just `~/.claude/session-stats/sessions.jsonl`: that
/// log only gets a line when a session *ends*, so it can't see work in flight.
/// Today's transcripts, by contrast, always exist on disk. The log is still read
/// as a fallback for sessions whose transcript has gone missing.
///
/// Files are read incrementally (byte offset per file) so a 30s refresh over a
/// 20 MB day costs almost nothing after the first pass.
final class Scanner {
    struct Paths {
        var projects: URL
        var log: URL

        static func resolve() -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let env = ProcessInfo.processInfo.environment
            let claude = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude")
            let log = env["CLAUDE_SESSION_STATS_LOG"].map { URL(fileURLWithPath: $0) }
                ?? claude.appendingPathComponent("session-stats/sessions.jsonl")
            return Paths(projects: claude.appendingPathComponent("projects"), log: log)
        }
    }

    /// A session is "live" if its transcript grew in the last few minutes.
    private static let liveWindow: TimeInterval = 5 * 60
    /// Days of per-file state kept in memory (today plus a margin for midnight).
    private static let retainDays = 3
    /// Bytes read per pass. Bounds peak memory on the first, large scan.
    private static let chunkSize = 1 << 18   // 256 KB

    private struct FileState {
        var offset: UInt64 = 0
        var partial = Data()
        /// Usage is repeated on every content block of a message, so requests
        /// are deduped on requestId+message.id — without it totals run 2-4x high.
        var seen = Set<String>()
        var byDay: [String: [String: Totals]] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        var lastTimestamp: Date?
    }

    private struct LogRecord {
        var day: String
        var output: Int
        var byModel: [String: Totals]
    }

    private var files: [String: FileState] = [:]
    private var logOffset: UInt64 = 0
    private var logPartial = Data()
    private var logRecords: [String: LogRecord] = [:]   // session id -> best record
    private let paths = Paths.resolve()

    // MARK: - Public

    func snapshot(for date: Date = Date()) -> DaySnapshot {
        let today = Fmt.localDay(date)
        let keepFrom = Calendar.current.date(byAdding: .day,
                                             value: -(Self.retainDays - 1),
                                             to: Calendar.current.startOfDay(for: date))!

        let transcripts = discoverTranscripts(modifiedSince: keepFrom)
        files = files.filter { transcripts[$0.key] != nil }
        for (path, isSubagent) in transcripts {
            var state = files[path] ?? FileState()
            ingest(path: path, isSubagent: isSubagent, into: &state)
            prune(&state, keeping: keepFrom)
            files[path] = state
        }

        var snap = DaySnapshot(day: today)
        var onDisk = Set<String>()
        // "Active" always means recently, not recently-relative-to-the-day
        // being queried — otherwise every past day reads as fully live.
        let liveCutoff = Date().addingTimeInterval(-Self.liveWindow)

        for state in files.values {
            if let models = state.byDay[today] {
                for (model, totals) in models { snap.byModel[model, default: Totals()] += totals }
            }
            if let ids = state.sessionsByDay[today] {
                snap.sessions.formUnion(ids)
                onDisk.formUnion(ids)
                if let last = state.lastTimestamp, last > liveCutoff {
                    snap.liveSessions.formUnion(ids)
                }
            }
        }
        // Sessions on disk for other days still count as "has a transcript".
        for state in files.values {
            for ids in state.sessionsByDay.values { onDisk.formUnion(ids) }
        }

        ingestLog(keeping: keepFrom)
        for (sid, rec) in logRecords where rec.day == today && !onDisk.contains(sid) {
            for (model, totals) in rec.byModel { snap.byModel[model, default: Totals()] += totals }
            snap.sessions.insert(sid)
        }

        snap.scannedAt = date
        return snap
    }

    // MARK: - Discovery

    /// Returns path -> isSubagentTranscript. A file untouched since `cutoff`
    /// cannot contain rows newer than `cutoff`, so mtime is a sound prefilter.
    private func discoverTranscripts(modifiedSince cutoff: Date) -> [String: Bool] {
        var out: [String: Bool] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: paths.projects, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return out }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            let name = url.lastPathComponent
            let isSubagent = url.deletingLastPathComponent().lastPathComponent == "subagents"
                || name.hasPrefix("agent-")
            out[url.path] = isSubagent
        }
        return out
    }

    // MARK: - Transcript ingest

    /// Streams the new bytes of one transcript through a fixed buffer.
    ///
    /// This deliberately uses read(2) rather than `FileHandle`/`Data`: handing
    /// back a fresh `Data` per chunk pushed peak RSS past 140 MB on a 20 MB day,
    /// which is absurd for a menu bar app. A reused buffer holds it near the
    /// process baseline.
    private func ingest(path: String, isSubagent: Bool, into state: inout FileState) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let end = lseek(fd, 0, SEEK_END)
        guard end >= 0 else { return }
        let size = UInt64(end)
        if size < state.offset {          // truncated or replaced — start over
            state = FileState()
        }
        guard size > state.offset else { return }
        guard lseek(fd, off_t(state.offset), SEEK_SET) >= 0 else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { buffer.deallocate() }

        // Carries a line split across chunks — or across passes, since a
        // transcript's last line may be half-written when we reach it.
        var pending = [UInt8](state.partial)
        state.partial = Data()

        while true {
            let n = read(fd, buffer, Self.chunkSize)
            guard n > 0 else { break }
            state.offset += UInt64(n)

            let chunk = UnsafeBufferPointer(start: buffer, count: n)
            var lineStart = 0
            for i in 0..<n where chunk[i] == 0x0A {
                if pending.isEmpty {
                    consume(line: chunk[lineStart..<i], isSubagent: isSubagent, into: &state)
                } else {
                    pending.append(contentsOf: chunk[lineStart..<i])
                    pending.withUnsafeBufferPointer {
                        consume(line: $0[...], isSubagent: isSubagent, into: &state)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
                lineStart = i + 1
            }
            if lineStart < n { pending.append(contentsOf: chunk[lineStart..<n]) }
        }
        state.partial = Data(pending)
    }

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)

    /// Substring search over raw bytes — cheaper than materialising a String or
    /// a Data copy for every line of a multi-megabyte transcript.
    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>.SubSequence,
                                 _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count, let first = needle.first else { return false }
        let limit = haystack.endIndex - needle.count
        var i = haystack.startIndex
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    private func consume(line: UnsafeBufferPointer<UInt8>.SubSequence,
                         isSubagent: Bool, into state: inout FileState) {
        guard line.count > 2 else { return }
        // Only assistant rows carry usage; skipping the rest avoids parsing
        // megabytes of tool results on every pass.
        guard Self.contains(line, Self.assistantMarker) else { return }

        // One pool per line. A parsed row costs several times its JSON bytes —
        // mostly the `content` blocks we never look at.
        autoreleasepool {
            parseAssistant(line: line, isSubagent: isSubagent, into: &state)
        }
    }

    private func parseAssistant(line: UnsafeBufferPointer<UInt8>.SubSequence, isSubagent: Bool,
                                into state: inout FileState) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant" else { return }
        // Subagent turns appear both in the parent transcript (as sidechain) and
        // in their own file; count them once, from their own file.
        if !isSubagent, obj["isSidechain"] as? Bool == true { return }

        guard let message = obj["message"] as? [String: Any] else { return }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }

        let key = "\(obj["requestId"] as? String ?? "")|\(message["id"] as? String ?? "")"
        guard !state.seen.contains(key) else { return }
        state.seen.insert(key)

        guard let tsString = obj["timestamp"] as? String,
              let ts = Fmt.parseTimestamp(tsString) else { return }
        if state.lastTimestamp == nil || ts > state.lastTimestamp! { state.lastTimestamp = ts }

        let day = Fmt.localDay(ts)
        let usage = message["usage"] as? [String: Any] ?? [:]
        var totals = Totals()
        totals.requests = 1
        totals.inputUncached = usage["input_tokens"] as? Int ?? 0
        totals.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        totals.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        totals.output = usage["output_tokens"] as? Int ?? 0
        // The TTL split decides whether a cache write bills at 2x or 1.25x.
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        totals.cacheWrite1h = creation["ephemeral_1h_input_tokens"] as? Int ?? 0

        state.byDay[day, default: [:]][model, default: Totals()] += totals
        if let sid = obj["sessionId"] as? String {
            state.sessionsByDay[day, default: []].insert(sid)
        }
    }

    private func prune(_ state: inout FileState, keeping cutoff: Date) {
        let oldest = Fmt.localDay(cutoff)
        state.byDay = state.byDay.filter { $0.key >= oldest }
        state.sessionsByDay = state.sessionsByDay.filter { $0.key >= oldest }
    }

    // MARK: - sessions.jsonl fallback

    private func ingestLog(keeping cutoff: Date) {
        guard let handle = FileHandle(forReadingAtPath: paths.log.path) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < logOffset { logOffset = 0; logPartial = Data(); logRecords = [:] }
        guard size > logOffset else { return }
        do { try handle.seek(toOffset: logOffset) } catch { return }
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        logOffset = size

        var buffer = logPartial
        buffer.append(chunk)
        logPartial = Data()

        autoreleasepool {
            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: 0x0A) {
                handleLog(line: buffer[start..<nl])
                start = buffer.index(after: nl)
            }
            if start < buffer.endIndex { logPartial = Data(buffer[start...]) }
        }

        let oldest = Fmt.localDay(cutoff)
        logRecords = logRecords.filter { $0.value.day >= oldest }
    }

    private func handleLog(line: Data.SubSequence) {
        guard line.count > 2,
              let rec = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let sid = rec["session_id"] as? String,
              let endedAt = (rec["ended_at"] ?? rec["logged_at"]) as? String,
              let ts = Fmt.parseTimestamp(endedAt),
              let grand = rec["grand_total"] as? [String: Any] else { return }

        let output = grand["output_tokens"] as? Int ?? 0
        // A session can be logged more than once (/clear, backfill); the record
        // with the most output tokens is the complete one.
        if let existing = logRecords[sid], existing.output >= output { return }

        var byModel: [String: Totals] = [:]
        for (model, raw) in (grand["by_model"] as? [String: [String: Any]] ?? [:]) {
            byModel[model] = Totals(
                requests: raw["requests"] as? Int ?? 0,
                inputUncached: raw["input_tokens"] as? Int ?? 0,
                cacheWrite: raw["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: raw["cache_read_input_tokens"] as? Int ?? 0,
                output: raw["output_tokens"] as? Int ?? 0)
        }
        logRecords[sid] = LogRecord(day: Fmt.localDay(ts), output: output, byModel: byModel)
    }
}
