import Foundation

// MARK: - Timestamps

/// Parser for the timestamps Claude Code writes into its session JSONL
/// (`2026-09-15T15:20:08.482Z`).
///
/// Hand-rolled rather than `ISO8601DateFormatter` for two reasons: this runs
/// over every line of every transcript delta, and `DateFormatter` subclasses
/// are not documented thread-safe, so a shared one would be a latent data race
/// the moment tails move off the main actor. The shape Claude Code emits is
/// fixed and trivially scannable. Anything that isn't that shape returns nil —
/// a missing timestamp degrades a row to "unknown", which is honest, whereas a
/// silently wrong one would make the "waiting on you" badge lie.
public enum TranscriptTime {

    /// `YYYY-MM-DDTHH:MM:SS[.fff]Z` → `Date`. Returns nil for any other shape,
    /// including non-UTC offsets (Claude Code always writes `Z`).
    public static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        // Shortest accepted form is "YYYY-MM-DDTHH:MM:SSZ" = 20 bytes.
        guard b.count >= 20 else { return nil }
        guard b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":")
        else { return nil }

        func num(_ lo: Int, _ hi: Int) -> Int? {
            var v = 0
            for i in lo..<hi {
                let c = b[i]
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int(c - UInt8(ascii: "0"))
            }
            return v
        }
        guard let year = num(0, 4), let month = num(5, 7), let day = num(8, 10),
              let hour = num(11, 13), let minute = num(14, 16), let second = num(17, 19)
        else { return nil }
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        var fraction = 0.0
        var i = 19
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") {
                fraction += Double(b[i] - UInt8(ascii: "0")) * scale
                scale /= 10
                i += 1
            }
        }
        guard i < b.count, b[i] == UInt8(ascii: "Z") else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: epoch)
    }

    /// Days since 1970-01-01 from a proleptic Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Avoids `Calendar`, which would dominate the cost of
    /// parsing a transcript and drags in the user's locale/timezone for a value
    /// that is defined to be UTC.
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - Activity

/// A tool call the assistant started and that has no result yet.
public struct PendingTool: Equatable, Sendable {
    public let id: String
    public let name: String
    public let startedAt: Date

    public init(id: String, name: String, startedAt: Date) {
        self.id = id; self.name = name; self.startedAt = startedAt
    }
}

/// What a live Claude session is doing right now, as far as its transcript can
/// tell us.
///
/// The distinction that earns the island its keep is `waitingOnYou` vs
/// `working`: both look identical in the file (a `tool_use` with no matching
/// `tool_result`), and only elapsed time separates "a permission prompt is on
/// screen" from "a build is running". See `SessionActivity.Thresholds`.
public enum SessionActivity: Equatable, Sendable {
    /// A tool has been outstanding longer than the debounce — most likely a
    /// permission prompt waiting for a keystroke.
    case waitingOnYou(tool: String, since: Date)
    /// A tool is outstanding but still within the debounce window.
    case working(tool: String, since: Date)
    /// The assistant finished its turn; the session is waiting for a prompt.
    case awaitingPrompt(since: Date?)
    /// A prompt or tool result landed and the assistant has not replied yet.
    case thinking(since: Date?)
    /// Nothing parseable — a transcript we could not read or that is empty.
    case unknown

    /// Tools whose whole purpose is to stop and ask the human.
    ///
    /// These need no debounce and no inference: the moment one is outstanding,
    /// the session is blocked on you by definition. Measured against a real
    /// transcript, `AskUserQuestion` sat unanswered for 62 minutes while every
    /// `Bash` call in the same session finished in a median of 0.1s — the two
    /// populations do not overlap, so guessing between them was never necessary.
    public static let blockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Tuning constants for turning the tool_use/tool_result gap into a state.
    public struct Thresholds: Equatable, Sendable {
        /// How long a tool may be outstanding before it reads as "waiting on
        /// you". Below this everything is just `working`.
        public var debounce: TimeInterval
        /// Beyond this, an outstanding tool is treated as debris rather than a
        /// live prompt — we joined the transcript mid-stream, or the session
        /// was killed with a tool in flight. Without this, any abandoned
        /// session would badge "waiting on you" forever.
        public var abandonAfter: TimeInterval
        /// Whether to guess at a permission prompt from the tool_use/tool_result
        /// gap at all.
        ///
        /// **False whenever the Claude Code hook is in effect**, because then a
        /// real prompt announces itself and the guess can only add mistakes: a
        /// slow tool that a `permissions.allow` rule auto-approved raises no
        /// prompt, yet the debounce would still fire on it. The guess is a
        /// fallback for the window where the hook isn't active — a session that
        /// was already running when it was installed, or an entry another tool
        /// has overwritten.
        public var inferPermissionPrompts: Bool

        public init(debounce: TimeInterval = 8,
                    abandonAfter: TimeInterval = 1_800,
                    inferPermissionPrompts: Bool = true) {
            self.debounce = debounce
            self.abandonAfter = abandonAfter
            self.inferPermissionPrompts = inferPermissionPrompts
        }

        public static let `default` = Thresholds()
    }

    /// Sort order for the island list: the states that want the user's
    /// attention float to the top. Lower sorts first.
    public var rank: Int {
        switch self {
        case .waitingOnYou:   return 0
        case .awaitingPrompt: return 1
        case .working:        return 2
        case .thinking:       return 3
        case .unknown:        return 4
        }
    }

    /// Whether this state should drive an ambient badge.
    public var needsAttention: Bool {
        if case .waitingOnYou = self { return true }
        return false
    }

    /// When this state began, if known.
    public var since: Date? {
        switch self {
        case .waitingOnYou(_, let d), .working(_, let d): return d
        case .awaitingPrompt(let d), .thinking(let d):    return d
        case .unknown:                                     return nil
        }
    }

    /// Short label for a badge. Says *what kind* of block it is, because
    /// "answer a question" and "approve a command" want different reactions.
    public var label: String {
        switch self {
        case .waitingOnYou(let tool, _):
            switch tool {
            case "AskUserQuestion": return "asking you"
            case "ExitPlanMode":    return "plan approval"
            case "approval":        return "approval needed"
            default:                return "needs approval"
            }
        case .working(let tool, _):  return tool.lowercased()
        case .awaitingPrompt:        return "your turn"
        case .thinking:              return "thinking"
        case .unknown:               return "unknown"
        }
    }
}

/// Which harness wrote a transcript. flow can bootstrap a task under either
/// (`flow do --harness claude|codex`), and the two write entirely different
/// JSONL, so every transcript carries its format.
public enum TranscriptFormat: String, Equatable, Sendable, CaseIterable {
    case claude
    case codex

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

// MARK: - Parser

/// Folds Claude Code transcript lines into a running picture of one session.
///
/// Deliberately a value type with no IO: the harness feeds it synthetic lines,
/// and `TranscriptTail` feeds it real ones. It is append-only and incremental —
/// `consume` is called once per line ever read, so watching a session costs
/// only the bytes that were appended since the last event.
///
/// Unknown line types (`attachment`, `mode`, `ai-title`, `file-history-snapshot`
/// and whatever Claude Code adds next) are skipped rather than rejected, so a
/// format addition degrades to "no new information" instead of a parse failure.
public struct TranscriptParser: Sendable {

    /// What the most recent meaningful entry was. Distinguishes "the assistant
    /// stopped and it's your move" from "the assistant is mid-reply".
    public enum LastEntry: Equatable, Sendable {
        case assistantText
        case userPrompt
        case toolResult
    }

    /// Outstanding tool calls, oldest first (insertion order is chronological
    /// because the transcript is append-only).
    public private(set) var pending: [PendingTool] = []
    /// Timestamp of the most recent entry we understood.
    public private(set) var lastEventAt: Date?
    /// Kind of the most recent entry we understood.
    public private(set) var lastEntry: LastEntry?
    /// Lines seen that were not valid JSON. A non-zero count on a file that
    /// should be pure JSONL means our tail framing is off, so it is worth
    /// surfacing rather than swallowing.
    public private(set) var malformedLines = 0
    /// The directory the session was launched from, as the transcript records
    /// it. Read from the file rather than decoded from the project directory
    /// name: `-Users-p-dev-projects-flow-bar` cannot be turned back into a path
    /// unambiguously, because a real directory may itself contain a dash.
    public private(set) var cwd: String?
    /// Git branch, when the transcript records one.
    public private(set) var gitBranch: String?
    /// Codex only: the transcript said outright that it is blocked on a human
    /// decision (`*_approval_request`). When this is set the debounce is
    /// bypassed, because there is nothing left to infer.
    public private(set) var awaitingApproval = false

    /// The session's current permission mode, as it last reported one.
    ///
    /// Load-bearing for precision: in a mode that never prompts, a tool that has
    /// been outstanding for a while is a *slow tool*, full stop — there is no
    /// prompt it could be waiting on. Without this, every long build in an
    /// auto-approving session reads as "waiting on you", which is exactly the
    /// false alarm that makes an alert worth ignoring.
    public private(set) var permissionMode: String?

    /// Modes in which no permission prompt can appear, so an outstanding tool
    /// must never be *inferred* to be one.
    ///
    /// `auto` belongs here because its classifier answers immediately — an
    /// auto-mode denial arrives as a normal tool_result, it does not hang.
    public static let neverPromptingModes: Set<String> = ["bypassPermissions", "auto"]

    /// Whether a permission prompt is even possible in this session right now.
    /// Unknown modes count as possible: missing the alert is worse than a rare
    /// false one, and an unrecognised mode is more likely new than never-prompting.
    public var mayPrompt: Bool {
        guard let permissionMode else { return true }
        return !Self.neverPromptingModes.contains(permissionMode)
    }

    public init() {}

    /// Fold one raw JSONL line into the state.
    public mutating func consume(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            malformedLines += 1
            return
        }
        consume(object: obj)
    }

    /// Fold one already-decoded JSONL object into the state. Split out so the
    /// harness can build objects directly instead of hand-writing JSON.
    public mutating func consume(object obj: [String: Any]) {
        // The two formats are structurally disjoint: Claude Code puts the
        // substance in `message`, Codex wraps everything in `payload`. Sniffing
        // per line rather than per file means a caller never has to declare the
        // format, and a file that somehow mixes them still parses.
        if obj["payload"] is [String: Any] {
            consumeCodex(obj)
        } else {
            consumeClaude(obj)
        }
    }

    private mutating func consumeClaude(_ obj: [String: Any]) {
        // Provenance is worth taking from ANY line that carries it — including
        // the `attachment` entries that are otherwise activity-free.
        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
        // Claude Code writes the mode both as its own `permission-mode` line and
        // as a field on user/assistant entries; take it from whichever arrives.
        if let m = obj["permissionMode"] as? String, !m.isEmpty { permissionMode = m }

        guard let type = obj["type"] as? String, type == "assistant" || type == "user" else {
            return   // mode / attachment / ai-title / snapshot lines carry no activity
        }
        let at = (obj["timestamp"] as? String).flatMap(TranscriptTime.parse)
        guard let message = obj["message"] as? [String: Any] else { return }

        // `message.content` is either a plain string (a typed user prompt) or an
        // array of blocks. Normalise to blocks.
        var blocks: [[String: Any]] = []
        if let s = message["content"] as? String {
            blocks = [["type": "text", "text": s]]
        } else if let arr = message["content"] as? [Any] {
            blocks = arr.compactMap { $0 as? [String: Any] }
        }
        guard !blocks.isEmpty else { return }

        if type == "assistant" {
            var sawTool = false
            var sawText = false
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    guard let id = b["id"] as? String else { continue }
                    sawTool = true
                    let name = (b["name"] as? String) ?? "tool"
                    // A tool_use with no timestamp cannot be aged, so it can
                    // never become "waiting on you". Drop it rather than
                    // anchoring it to `now` and inventing an age.
                    if let at { pending.append(PendingTool(id: id, name: name, startedAt: at)) }
                case "text", "thinking":
                    sawText = true
                default:
                    break
                }
            }
            if sawTool {
                // A turn that ends in tool calls is not "your move" — the
                // outstanding-tool branch of `activity` owns the state now.
                lastEntry = nil
            } else if sawText {
                lastEntry = .assistantText
            }
            if at != nil { lastEventAt = at }
            return
        }

        // type == "user": either real input, or the tool results being fed back.
        var sawResult = false
        var sawText = false
        for b in blocks {
            switch b["type"] as? String {
            case "tool_result":
                sawResult = true
                if let id = b["tool_use_id"] as? String {
                    pending.removeAll { $0.id == id }
                }
            case "text":
                sawText = true
            default:
                break
            }
        }
        // `isMeta` marks system-injected user entries (hook output, reminders).
        // They are not the human typing, so they must not read as a new prompt.
        let isMeta = (obj["isMeta"] as? Bool) ?? false
        if sawResult {
            lastEntry = .toolResult
        } else if sawText && !isMeta {
            lastEntry = .userPrompt
        }
        if at != nil { lastEventAt = at }
    }

    /// Fold one Codex rollout line.
    ///
    /// Codex is the easier of the two to read, and in one respect strictly
    /// better: where Claude Code leaves "is this a permission prompt or a slow
    /// build?" to be inferred from elapsed time, Codex emits an explicit
    /// `*_approval_request` event, and an explicit `task_complete` when a turn
    /// ends. Both are used here in preference to inference.
    private mutating func consumeCodex(_ obj: [String: Any]) {
        guard let payload = obj["payload"] as? [String: Any] else { return }
        let at = (obj["timestamp"] as? String).flatMap(TranscriptTime.parse)

        // `session_meta` and `turn_context` both carry the launch directory.
        if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
        // Codex's equivalent of a permission mode. "never" means it will not ask.
        if let policy = payload["approval_policy"] as? String, !policy.isEmpty {
            permissionMode = (policy == "never") ? "bypassPermissions" : policy
        }

        guard let kind = payload["type"] as? String else { return }

        switch kind {
        case "function_call", "custom_tool_call":
            guard let id = payload["call_id"] as? String else { return }
            let name = (payload["name"] as? String) ?? "tool"
            if let at { pending.append(PendingTool(id: id, name: name, startedAt: at)) }
            lastEntry = nil

        case "function_call_output", "custom_tool_call_output":
            if let id = payload["call_id"] as? String { pending.removeAll { $0.id == id } }
            awaitingApproval = false
            lastEntry = .toolResult

        case "task_complete", "turn_aborted":
            // An explicit end of turn. Anything still outstanding is moot —
            // which is exactly the ambiguity the Claude path has to debounce.
            pending.removeAll()
            awaitingApproval = false
            lastEntry = .assistantText

        case "agent_message":
            lastEntry = .assistantText

        case "user_message":
            awaitingApproval = false
            lastEntry = .userPrompt

        case "task_started":
            awaitingApproval = false
            lastEntry = .userPrompt   // a turn is running; the assistant is thinking

        case let k where k.hasSuffix("_approval_request"):
            // `exec_approval_request`, `apply_patch_approval_request`, …
            // Codex is telling us outright that it is blocked on the human.
            awaitingApproval = true
            lastEntry = nil

        default:
            // token_count, reasoning, web_search, patch_apply_end, developer
            // `message` records — no bearing on whether the session needs you.
            return
        }
        if at != nil { lastEventAt = at }
    }

    /// Resolve the accumulated state into a displayable activity.
    ///
    /// `now` is injected rather than read from the clock so the harness can
    /// test the debounce boundary without sleeping.
    public func activity(now: Date,
                         thresholds: SessionActivity.Thresholds = .default) -> SessionActivity {
        // Ignore tools old enough to be debris (see `abandonAfter`).
        let live = pending.filter { now.timeIntervalSince($0.startedAt) < thresholds.abandonAfter }
        // 1. Codex said outright that it is blocked. No inference to do.
        if awaitingApproval {
            return .waitingOnYou(tool: live.first?.name ?? "approval",
                                 since: live.first?.startedAt ?? lastEventAt ?? now)
        }
        // 2. A tool whose entire job is to stop and ask. Also exact — and it is
        //    the common case, since `AskUserQuestion` is how Claude asks
        //    anything. No debounce: the block starts the instant it is called.
        if let asking = live.first(where: { SessionActivity.blockingTools.contains($0.name) }) {
            return .waitingOnYou(tool: asking.name, since: asking.startedAt)
        }
        if let oldest = live.first {
            // 3. Everything else is an ordinary tool that is merely taking a
            //    while. It can only be a permission prompt if this session is in
            //    a mode that prompts at all — in `auto` or `bypassPermissions`
            //    there is no prompt it could be waiting on, so a long call is a
            //    long call. Measured: `Bash` reached 10.3s in a real session
            //    while nothing was blocked, so inferring here without the mode
            //    check is how the alert learns to cry wolf.
            let age = now.timeIntervalSince(oldest.startedAt)
            return (thresholds.inferPermissionPrompts && mayPrompt && age >= thresholds.debounce)
                ? .waitingOnYou(tool: oldest.name, since: oldest.startedAt)
                : .working(tool: oldest.name, since: oldest.startedAt)
        }
        switch lastEntry {
        case .assistantText:        return .awaitingPrompt(since: lastEventAt)
        case .userPrompt, .toolResult: return .thinking(since: lastEventAt)
        case nil:                   return .unknown
        }
    }

    /// When the next *time-driven* state change is due, or nil if none is.
    ///
    /// This is the piece that makes a watch-only design honest. kqueue tells us
    /// when the file changes; it can never tell us that 8 seconds elapsed with
    /// nothing happening — which is exactly the transition into "waiting on
    /// you". Callers arm a single one-shot timer for this interval, and only
    /// while a tool is actually outstanding, instead of polling on a loop.
    public func nextTransition(now: Date,
                               thresholds: SessionActivity.Thresholds = .default) -> TimeInterval? {
        let live = pending.filter { now.timeIntervalSince($0.startedAt) < thresholds.abandonAfter }
        guard let oldest = live.first else { return nil }
        let remaining = thresholds.debounce - now.timeIntervalSince(oldest.startedAt)
        return remaining > 0 ? remaining : nil
    }
}
