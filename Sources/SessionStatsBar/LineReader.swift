import Foundation

/// Where a reader got to in an append-only JSONL file: how far it has read, and
/// the tail of a line that wasn't finished yet.
struct LineCursor {
    var offset: UInt64 = 0
    var partial = Data()
}

/// Streams the lines appended to a file since the last pass. Shared by the
/// Claude transcript scanner and the Codex rollout reader — both tail files
/// that grow by a line at a time and can reach tens of megabytes.
enum LineReader {
    /// Bytes read per pass. Bounds peak memory on the first, large scan.
    static let chunkSize = 1 << 18   // 256 KB

    /// Current size of the file, or nil if it can't be stat'ed. Callers compare
    /// it against their cursor to notice a truncated or replaced file *before*
    /// feeding new lines into state built from the old contents.
    static func size(of path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }

    /// Hands every complete line appended since `cursor` to `line`, without the
    /// trailing newline, and advances the cursor. A half-written last line is
    /// held in the cursor until a later pass completes it. A file that shrank is
    /// left alone — the caller checks `size(of:)` and resets its own state.
    ///
    /// This deliberately uses read(2) rather than `FileHandle`/`Data`: handing
    /// back a fresh `Data` per chunk pushed peak RSS past 140 MB on a 20 MB day,
    /// which is absurd for a menu bar app. A reused buffer holds it near the
    /// process baseline.
    static func readAppended(path: String, cursor: inout LineCursor,
                             line: (UnsafeBufferPointer<UInt8>.SubSequence) -> Void) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let end = lseek(fd, 0, SEEK_END)
        guard end >= 0, UInt64(end) > cursor.offset else { return }
        guard lseek(fd, off_t(cursor.offset), SEEK_SET) >= 0 else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        // Carries a line split across chunks — or across passes, since a
        // file's last line may be half-written when we reach it.
        var pending = [UInt8](cursor.partial)
        cursor.partial = Data()

        while true {
            let n = read(fd, buffer, chunkSize)
            guard n > 0 else { break }
            cursor.offset += UInt64(n)

            let chunk = UnsafeBufferPointer(start: buffer, count: n)
            var lineStart = 0
            for i in 0..<n where chunk[i] == 0x0A {
                if pending.isEmpty {
                    line(chunk[lineStart..<i])
                } else {
                    pending.append(contentsOf: chunk[lineStart..<i])
                    pending.withUnsafeBufferPointer { line($0[...]) }
                    pending.removeAll(keepingCapacity: true)
                }
                lineStart = i + 1
            }
            if lineStart < n { pending.append(contentsOf: chunk[lineStart..<n]) }
        }
        cursor.partial = Data(pending)
    }

    /// Substring search over raw bytes — cheaper than materialising a String or
    /// a Data copy for every line of a multi-megabyte file.
    static func contains(_ haystack: UnsafeBufferPointer<UInt8>.SubSequence,
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
}
