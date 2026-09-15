import Foundation

/// Finds the transcript file for a harness session id.
///
/// **The transcript directory is keyed to the cwd the session was launched
/// from, not the task's `work_dir`.** A task whose work_dir is
/// `~/dev/projects/flow-bar` can easily have its transcript under
/// `-Users-…-dev-projects`, because that is where `flow do` was invoked. So the
/// path cannot be derived from the task at all — the session id (a UUID, and
/// therefore unique across every project directory) is the only usable key, and
/// finding it means probing each project directory for `<uuid>.jsonl`.
public enum SessionLocator {

    /// Default transcript root. Honors `CLAUDE_CONFIG_DIR` the way the CLI does,
    /// so a relocated config still resolves.
    public static var defaultProjectsRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .appendingPathComponent("projects")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
    }

    /// A session id is only usable as a filename if it looks like one. Guards
    /// the probe below against a malformed `flow show` parse turning into a
    /// path traversal (`../../etc/passwd.jsonl`).
    public static func isValidSessionID(_ id: String) -> Bool {
        guard id.count >= 8, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Codex's rollout root: `~/.codex/sessions`, laid out `YYYY/MM/DD/`.
    public static var defaultCodexRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// A transcript found on disk, and which harness wrote it.
    public struct Located: Equatable, Sendable {
        public let url: URL
        public let format: TranscriptFormat

        public init(url: URL, format: TranscriptFormat) {
            self.url = url
            self.format = format
        }
    }

    /// Whether a Codex rollout filename belongs to `sessionID`.
    ///
    /// Codex names files `rollout-<ISO timestamp>-<thread id>.jsonl`, so the id
    /// is a *suffix* of the stem rather than the whole of it — and matching on
    /// "contains" would let a timestamp digit sequence produce a false hit.
    public static func isCodexTranscript(filename: String, sessionID: String) -> Bool {
        guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return false }
        let stem = String(filename.dropLast(6))           // drop ".jsonl"
        return stem.hasSuffix("-" + sessionID)
    }

    /// Locate the transcript for a harness session id, whichever harness wrote
    /// it. Claude Code is probed first because it is the common case and costs
    /// a handful of `stat`s; the Codex tree needs a walk.
    public static func locate(sessionID: String,
                              claudeRoot: URL? = nil,
                              codexRoot: URL? = nil,
                              fileManager: FileManager = .default) -> Located? {
        guard isValidSessionID(sessionID) else { return nil }
        if let url = claudeTranscriptURL(sessionID: sessionID, root: claudeRoot,
                                         fileManager: fileManager) {
            return Located(url: url, format: .claude)
        }
        if let url = codexTranscriptURL(sessionID: sessionID, root: codexRoot,
                                        fileManager: fileManager) {
            return Located(url: url, format: .codex)
        }
        return nil
    }

    /// Locate `<sessionID>.jsonl` under any project directory in `root`.
    /// Returns nil if the id is malformed or no such transcript exists.
    public static func claudeTranscriptURL(sessionID: String,
                                           root: URL? = nil,
                                           fileManager: FileManager = .default) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        let root = root ?? defaultProjectsRoot
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let filename = sessionID + ".jsonl"
        for dir in children {
            let candidate = dir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Walk `~/.codex/sessions/YYYY/MM/DD/` for this thread's rollout file.
    ///
    /// A walk rather than a computed path: the date directories record when the
    /// session *started*, which flow does not tell us. The tree is shallow and
    /// holds one file per session, and this only runs for tasks flow already
    /// reported live, so the cost is bounded by how many sessions have ever run.
    public static func codexTranscriptURL(sessionID: String,
                                          root: URL? = nil,
                                          fileManager: FileManager = .default) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        let root = root ?? defaultCodexRoot
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in walker
        where isCodexTranscript(filename: url.lastPathComponent, sessionID: sessionID) {
            return url
        }
        return nil
    }
}

/// An incremental reader over one session transcript.
///
/// Reads only the bytes appended since the last call, so watching a live
/// session costs the size of the delta rather than the size of the file. That
/// is what makes a continuous watch defensible: an idle session costs nothing,
/// and a busy one costs the few KB it just wrote.
///
/// Not `Sendable` on purpose — it owns a file offset and a carry buffer, and is
/// used from a single actor (`SessionMonitor`, on the main actor). Making it an
/// actor would buy nothing but `await`s on a few-KB read.
public final class TranscriptTail {

    /// How far back to read when first attaching to an existing transcript.
    ///
    /// Transcripts are line-heavy (tool results routinely run to several KB per
    /// line), so 256 KB is on the order of tens of entries — comfortably more
    /// than the one turn needed to see whether a tool is outstanding right now,
    /// and small enough that attaching stays a few milliseconds.
    public static let initialWindow = 256 * 1024

    public let url: URL
    public private(set) var parser = TranscriptParser()
    /// Byte offset we have consumed up to.
    private var offset: UInt64 = 0
    /// A trailing partial line held back until its newline arrives. Claude Code
    /// appends a line at a time, but a kqueue write event can still land
    /// mid-write, and half a JSON object must never reach the parser.
    private var carry = Data()
    private var attached = false

    public init(url: URL) {
        self.url = url
    }

    /// Consume everything appended since the last call.
    ///
    /// Returns true if any new line was folded in, so callers can skip a UI
    /// update on a no-op event (kqueue fires on metadata changes too).
    @discardableResult
    public func refresh() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        if !attached {
            // First read: start one window back from the end, and drop whatever
            // partial line we land in the middle of.
            attached = true
            let start = size > UInt64(Self.initialWindow) ? size - UInt64(Self.initialWindow) : 0
            offset = start
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
            offset = size
            var body = data
            if start > 0, let nl = body.firstIndex(of: 0x0A) {
                body = body[body.index(after: nl)...]
            }
            return feed(body)
        }

        if size < offset {
            // Truncated or replaced (a `--fresh` session reusing the path).
            // Everything we knew is void; re-attach from scratch.
            parser = TranscriptParser()
            carry.removeAll()
            attached = false
            return refresh()
        }
        guard size > offset else { return false }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        offset = size
        return feed(data)
    }

    /// Split `data` (plus any carried partial line) on newlines and fold each
    /// complete line into the parser, carrying the remainder.
    private func feed(_ data: Data) -> Bool {
        var buffer = carry
        buffer.append(data)
        carry.removeAll()

        var consumed = false
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let lineData = buffer[start..<nl]
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                parser.consume(line: line)
                consumed = true
            }
            start = buffer.index(after: nl)
        }
        if start < buffer.endIndex {
            carry = Data(buffer[start...])
            // A "line" this long is not a line — the file is not what we think
            // it is. Drop it rather than growing the buffer without bound.
            if carry.count > 8 * 1024 * 1024 { carry.removeAll() }
        }
        return consumed
    }

    /// Current activity, given the clock and the user's tuning.
    public func activity(now: Date = Date(),
                         thresholds: SessionActivity.Thresholds = .default) -> SessionActivity {
        parser.activity(now: now, thresholds: thresholds)
    }

    /// Seconds until the next purely time-driven state change, if any.
    public func nextTransition(now: Date = Date(),
                               thresholds: SessionActivity.Thresholds = .default) -> TimeInterval? {
        parser.nextTransition(now: now, thresholds: thresholds)
    }
}
