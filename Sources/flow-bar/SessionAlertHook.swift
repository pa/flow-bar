import FlowBarCore
import Foundation

/// Installs (and removes) the Claude Code `Notification` hook that tells
/// flow-bar the moment a session stops and asks for something.
///
/// The JSONL alone cannot see a permission prompt: Claude Code writes the
/// `tool_use` and then nothing at all until the prompt is answered, so from the
/// file a pending prompt and a slow build are the same bytes. The hook closes
/// that gap exactly, for every tool, with no debounce.
///
/// ## What it writes where
///
/// - A small POSIX script under Application Support, which does one thing:
///   `cat` its stdin into a file. No `jq`, no binary, nothing to keep in step
///   with the app.
/// - One appended entry in `~/.claude/settings.json`. **That file belongs to the
///   user and other tools write to it too**, so the splice is surgical (see
///   `ClaudeHookConfig`) and the previous contents are copied to a `.flow-bar
///   .bak` alongside before the first write.
enum SessionAlertHook {

    /// Where the hook drops payloads and where the script lives.
    static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/flow-bar")
    }
    static var alertsDir: URL { supportDir.appendingPathComponent("alerts") }
    static var scriptURL: URL { supportDir.appendingPathComponent("session-alert-hook.sh") }

    static var settingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .appendingPathComponent("settings.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    /// The hook body.
    ///
    /// `mktemp` + `mv` rather than writing the final name directly: flow-bar is
    /// watching this directory and would otherwise read a half-written payload.
    /// Every failure path exits 0 — a hook that errors is noise in the user's
    /// session, and a missed alert is a far smaller problem than a broken one.
    static let script = """
    #!/bin/sh
    # flow-bar session alerts. Installed by flow-bar; safe to delete.
    #
    # Claude Code pipes the Notification payload on stdin. Drop it where
    # flow-bar is watching and get out of the way — this runs inside the user's
    # session, so it must be fast and must never fail loudly.
    DIR="$HOME/Library/Application Support/flow-bar/alerts"
    mkdir -p "$DIR" 2>/dev/null || exit 0
    f=$(mktemp "$DIR/alert.XXXXXXXX" 2>/dev/null) || exit 0
    cat > "$f" 2>/dev/null || { rm -f "$f"; exit 0; }
    # Rename into place so a reader never sees a partial file.
    mv "$f" "$f.json" 2>/dev/null || rm -f "$f"
    exit 0
    """

    // MARK: Install / remove

    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: alertsDir, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            FlowClient.log("session-alert hook: could not write script — \(error)")
            return false
        }
        return updateSettings { ClaudeHookConfig.install(into: $0, scriptPath: scriptURL.path) }
    }

    @discardableResult
    static func remove() -> Bool {
        updateSettings { ClaudeHookConfig.remove(from: $0) }
    }

    static var isInstalled: Bool {
        guard let settings = readSettings() else { return false }
        return ClaudeHookConfig.isInstalled(in: settings)
            && FileManager.default.isExecutableFile(atPath: scriptURL.path)
    }

    // MARK: settings.json

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Present but unparseable. Refuse to touch it rather than replace
            // it with something well-formed and wrong.
            return nil
        }
        return obj
    }

    /// Read, transform, write back — preserving key order as best JSON allows
    /// and backing up the original once.
    private static func updateSettings(_ transform: ([String: Any]) -> [String: Any]) -> Bool {
        guard let current = readSettings() else {
            FlowClient.log("session-alert hook: \(settingsURL.path) is not valid JSON — leaving it alone")
            return false
        }
        let updated = transform(current)
        guard !NSDictionary(dictionary: updated).isEqual(to: current) else { return true }

        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("flow-bar.bak")
            if !fm.fileExists(atPath: backup.path) {
                try? fm.copyItem(at: settingsURL, to: backup)
            }
        }
        do {
            // `.sortedKeys` so repeated writes don't churn the file, and
            // `.withoutEscapingSlashes` so paths stay readable by a human.
            let data = try JSONSerialization.data(
                withJSONObject: updated,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            FlowClient.log("session-alert hook: updated \(settingsURL.path)")
            return true
        } catch {
            FlowClient.log("session-alert hook: could not write settings — \(error)")
            return false
        }
    }

    // MARK: Reading alerts

    /// Ingest every payload the hook has dropped, newest wins per session, and
    /// delete the files as they are read.
    ///
    /// Deleting on read is what keeps the directory from growing without bound;
    /// the in-memory copy is the live state from then on, and is cleared when
    /// the session's transcript shows activity past the alert.
    static func drain() -> [String: SessionAlert] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: alertsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [:] }

        var found: [String: SessionAlert] = [:]
        for file in files where file.pathExtension == "json" {
            let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if let data = try? Data(contentsOf: file),
               let alert = SessionAlert.decode(data, at: at) {
                // Several prompts can queue up for one session; the last one is
                // the one still on screen.
                if let existing = found[alert.sessionID], existing.at > alert.at { continue }
                found[alert.sessionID] = alert
            }
            try? fm.removeItem(at: file)
        }
        return found
    }
}
