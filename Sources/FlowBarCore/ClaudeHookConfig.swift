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

    /// The command string for a given script path.
    public static func command(scriptPath: String) -> String {
        "'\(scriptPath)' \(marker)"
    }

    /// Whether our entry is already present.
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        entries(in: settings).contains { isOurs($0) }
    }

    /// Add our entry, replacing any earlier version of it, and leaving every
    /// other hook — ours or anyone else's — exactly as it was.
    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Drop a stale entry of ours first, so installing twice can't stack.
        var list = entries(in: settings).filter { !isOurs($0) }
        list.append([
            "matcher": matcher,
            "hooks": [["type": "command",
                       "command": command(scriptPath: scriptPath),
                       "timeout": timeout]],
        ])
        hooks[event] = list
        settings["hooks"] = hooks
        return settings
    }

    /// Remove only our entry.
    ///
    /// Prunes the `Notification` key when it ends up empty, and the `hooks` key
    /// when *that* ends up empty, so uninstalling leaves no debris behind — but
    /// never touches either if someone else's entry is still there.
    public static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        let remaining = entries(in: settings).filter { !isOurs($0) }
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return settings
    }

    /// The `Notification` entries currently configured, in order.
    public static func entries(in settings: [String: Any]) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let list = hooks[event] as? [Any]
        else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// Whether a `Notification` entry is one flow-bar wrote.
    public static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [Any] else { return false }
        return inner.contains { step in
            guard let step = step as? [String: Any],
                  let command = step["command"] as? String
            else { return false }
            return command.contains(marker)
        }
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
    public static func decode(_ data: Data, at: Date) -> SessionAlert? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = obj["session_id"] as? String, !sessionID.isEmpty
        else { return nil }
        return SessionAlert(sessionID: sessionID,
                            kind: (obj["notification_type"] as? String) ?? "notification",
                            message: (obj["message"] as? String) ?? "",
                            at: at)
    }

    /// A short label for the row, derived from Claude Code's own wording where
    /// there is any — "Bash wants to run: npm test" beats a generic string.
    public var label: String {
        if !message.isEmpty { return message }
        switch kind {
        case "permission_prompt":  return "needs approval"
        case "idle_prompt":        return "waiting for you"
        case "agent_needs_input":  return "needs input"
        case "elicitation_dialog": return "needs input"
        default:                   return "waiting on you"
        }
    }
}
