import Foundation

/// One tool's `settings.json` hook entry, and the surgical splice that adds or
/// removes it.
///
/// **This edits a file the user owns and that other tools also write to** — a
/// real `~/.claude/settings.json` in the wild already carried CodeIsland's
/// `Notification` hook and orca's `PermissionRequest` hook. So every operation
/// is surgical: unknown keys are preserved untouched, other people's entries
/// are preserved untouched, and removal deletes only entries carrying our
/// marker. Pure dictionary transforms, no file IO, so the harness can prove
/// that on realistic input.
///
/// Claude Code and the praxis harness read the SAME hook schema — praxis maps
/// Claude's documented event names onto its own lifecycle events — so the
/// splice is shared and the two differ only in the fields below.
public struct HookSplice: Sendable {
    /// The event key under `hooks`.
    public let event: String

    /// The matcher to write, or nil to fire on every occurrence of the event.
    ///
    /// This is the one place the two harnesses genuinely diverge, and getting
    /// it wrong is silent: a matcher is a regex tested against a value the
    /// EVENT chooses, so a pattern written for the wrong value matches nothing
    /// and the hook simply never runs.
    public let matcher: String?

    /// Appended to our command as a shell comment so the entry is identifiable
    /// for removal even if the script path changes.
    public let marker: String

    /// Seconds the harness will wait for our hook. Small on purpose: the hook
    /// writes one small file and exits, and a generous timeout on an
    /// informational event buys nothing but a way to stall.
    public let timeout: Int

    public init(event: String, matcher: String?, marker: String, timeout: Int) {
        self.event = event
        self.matcher = matcher
        self.marker = marker
        self.timeout = timeout
    }

    /// The command string for a given script path.
    public func command(scriptPath: String) -> String {
        "'\(scriptPath)' \(marker)"
    }

    /// Whether our entry is already present.
    public func isInstalled(in settings: [String: Any]) -> Bool {
        entries(in: settings).contains { isOurs($0) }
    }

    /// Add our entry, replacing any earlier version of it, and leaving every
    /// other hook — ours or anyone else's — exactly as it was.
    public func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Drop a stale entry of ours first, so installing twice can't stack.
        var list = entries(in: settings).filter { !isOurs($0) }
        var entry: [String: Any] = [
            "hooks": [["type": "command",
                       "command": command(scriptPath: scriptPath),
                       "timeout": timeout]],
        ]
        // An absent matcher means "every occurrence". Writing an empty string
        // would mean the same to both harnesses, but an absent key is what
        // their own documented examples show, and it cannot be mistaken for a
        // pattern that failed to compile.
        if let matcher { entry["matcher"] = matcher }
        list.append(entry)
        hooks[event] = list
        settings["hooks"] = hooks
        return settings
    }

    /// Remove only our entry.
    ///
    /// Prunes the event key when it ends up empty, and the `hooks` key when
    /// *that* ends up empty, so uninstalling leaves no debris behind — but
    /// never touches either if someone else's entry is still there.
    public func remove(from settings: [String: Any]) -> [String: Any] {
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

    /// The entries currently configured for this event, in order.
    public func entries(in settings: [String: Any]) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let list = hooks[event] as? [Any]
        else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// Whether an entry is one flow-bar wrote.
    public func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [Any] else { return false }
        return inner.contains { step in
            guard let step = step as? [String: Any],
                  let command = step["command"] as? String
            else { return false }
            return command.contains(marker)
        }
    }
}

/// flow-bar's hook in the **praxis harness**'s `settings.json`.
///
/// ## Why `Notification`, and why with no matcher
///
/// praxis accepts Claude Code's hook names and maps them onto its own lifecycle
/// events: `Notification` resolves to `attention_needed`, which the harness
/// documents as firing "at the moment the runtime starts blocking on the user —
/// a permission prompt, an ask-tool question and equivalents", as an EDGE. That
/// is precisely the signal flow-bar wants, and it is observation-only: hooks on
/// it cannot block or contribute context, so a wedged flow-bar can never delay
/// a prompt the user is waiting on. Same reasoning that picked Claude's
/// `Notification` over `PermissionRequest`.
///
/// The matcher is deliberately ABSENT. praxis tests an event's matcher against
/// that event's `reason` — `waiting_permission` or `waiting_question` here —
/// NOT against Claude's `notification_type`. Carrying Claude's matcher across
/// would match nothing and the hook would never fire, which is the kind of
/// failure that looks like the feature simply not working. And since
/// `attention_needed` only fires when the runtime is actually blocked, every
/// occurrence is worth an alert: there is nothing to filter out, where Claude's
/// `Notification` also carries `auth_success` and quota chatter.
public enum PraxisHookConfig {
    public static let splice = HookSplice(
        event: "Notification",
        matcher: nil,
        marker: "# flow-bar-session-alert",
        timeout: 5)

    /// `<agentDir>/settings.json` — the same file `prx` reads its own settings
    /// from, resolved the way the rest of the app resolves the agent directory.
    public static func settingsURL() -> URL {
        URL(fileURLWithPath: PraxisClient.praxisAgentDir())
            .appendingPathComponent("settings.json")
    }
}
