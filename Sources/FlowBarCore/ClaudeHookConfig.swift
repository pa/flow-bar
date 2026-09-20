import Foundation

/// Adds and removes flow-bar's entry in `~/.claude/settings.json`.
///
/// **This edits a file the user owns and that other tools also write to** — a
/// real settings.json in the wild already carried CodeIsland's `Notification`
/// hook and orca's `PermissionRequest` hook. So every operation here is a
/// surgical splice: unknown keys are preserved untouched, other people's hook
/// entries are preserved untouched, and removal deletes only entries carrying
/// our marker. Pure dictionary transforms, no file IO, so the harness can prove
/// that on realistic input.
///
/// ## Why the `Notification` event and not `PermissionRequest`
///
/// Both fire when a tool needs approval, but `PermissionRequest` sits *in the
/// decision path* — it can allow/deny, and a slow or wedged hook delays the
/// prompt the user is waiting on. `Notification` is documented as informational
/// with no decision control, so the worst a broken flow-bar can do is fail to
/// notice something. For a feature whose entire job is to observe, that trade is
/// the whole ballgame.
///
/// Its `notification_type` matcher also covers more than permissions:
/// `permission_prompt`, `idle_prompt` and `agent_needs_input` are all "this
/// session has stopped and wants you".
public enum ClaudeHookConfig {

    /// Hook event we attach to.
    public static let event = "Notification"

    /// The notification types that mean "stopped, waiting for a human".
    /// Deliberately not `*`: `auth_success`, `agent_completed` and the quota
    /// notifications are informational and must not raise an alert.
    public static let matcher = "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog"

    /// Appended to our command as a shell comment so the entry is identifiable
    /// for removal even if the script path changes. (Same trick supacode uses in
    /// this user's Codex hooks, which is where the idea comes from.)
    public static let marker = "# flow-bar-session-alert"

    /// Seconds Claude Code will wait for our hook. Small on purpose: the hook
    /// writes one small file and exits, and a generous timeout on an
    /// informational event buys nothing but a way to stall.
    public static let timeout = 5

    /// The splice itself is shared with praxis, which reads the same schema —
    /// see `HookSplice`. Only the fields above are Claude's.
    public static let splice = HookSplice(event: event, matcher: matcher,
                                          marker: marker, timeout: timeout)

    /// The command string for a given script path.
    public static func command(scriptPath: String) -> String {
        splice.command(scriptPath: scriptPath)
    }

    /// Whether our entry is already present.
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        splice.isInstalled(in: settings)
    }

    /// Add our entry, replacing any earlier version of it, and leaving every
    /// other hook — ours or anyone else's — exactly as it was.
    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        splice.install(into: settings, scriptPath: scriptPath)
    }

    /// Remove only our entry.
    public static func remove(from settings: [String: Any]) -> [String: Any] {
        splice.remove(from: settings)
    }

    /// The `Notification` entries currently configured, in order.
    public static func entries(in settings: [String: Any]) -> [[String: Any]] {
        splice.entries(in: settings)
    }

    /// Whether a `Notification` entry is one flow-bar wrote.
    public static func isOurs(_ entry: [String: Any]) -> Bool {
        splice.isOurs(entry)
    }
}

/// One "this session is waiting for you" event, as written by the hook.
public struct SessionAlert: Equatable, Sendable {
    public let sessionID: String
    /// `permission_prompt`, `idle_prompt`, `agent_needs_input`, …
    public let kind: String
    /// Claude Code's own wording, e.g. "Bash wants to run: npm test".
    public let message: String
    /// When flow-bar ingested it. The hook payload carries no timestamp, so
    /// this is the file's own modification date — accurate to the moment the
    /// prompt appeared, since the hook runs synchronously with it.
    public let at: Date

    public init(sessionID: String, kind: String, message: String, at: Date) {
        self.sessionID = sessionID
        self.kind = kind
        self.message = message
        self.at = at
    }

    /// Decode one hook payload. Returns nil for anything without a session id,
    /// which is the only field we cannot do without.
    ///
    /// Both harnesses send a Claude-Code-shaped object, but they name the
    /// interesting parts differently: Claude has `notification_type` and a
    /// ready-made `message`, praxis has `reason` (`waiting_permission` /
    /// `waiting_question`), the `tool` that stopped, and the `question` text
    /// itself. Reading both here keeps the rest of the app on one vocabulary.
    public static func decode(_ data: Data, at: Date) -> SessionAlert? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = obj["session_id"] as? String, !sessionID.isEmpty
        else { return nil }

        let kind = (obj["notification_type"] as? String)
            ?? (obj["reason"] as? String)
            ?? "notification"

        // Prefer whatever wording the harness already produced: its own
        // sentence beats anything generic we could compose. praxis's
        // `question` IS the question the session stopped on.
        var message = (obj["message"] as? String) ?? (obj["question"] as? String) ?? ""
        if message.isEmpty, let tool = obj["tool"] as? String, !tool.isEmpty,
           kind == "waiting_permission"
        {
            message = "\(tool) needs approval"
        }
        return SessionAlert(sessionID: sessionID, kind: kind, message: message, at: at)
    }

    /// A short label for the row, derived from Claude Code's own wording where
    /// there is any — "Bash wants to run: npm test" beats a generic string.
    public var label: String {
        if !message.isEmpty { return message }
        switch kind {
        case "permission_prompt":   return "needs approval"
        case "idle_prompt":         return "waiting for you"
        case "agent_needs_input":   return "needs input"
        case "elicitation_dialog":  return "needs input"
        // praxis's own reasons for entering the waiting-for-input edge.
        case "waiting_permission":  return "needs approval"
        case "waiting_question":    return "needs input"
        default:                    return "waiting on you"
        }
    }
}
