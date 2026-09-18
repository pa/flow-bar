import AppKit
import FlowBarCore
import Foundation

/// Runs the Homebrew self-upgrade: write the script, launch it detached, quit.
///
/// See `BrewUpgrade` for *why* a source install delegates to brew rather than
/// installing the released zip. This is the mechanics.
///
/// The ordering matters. flow-bar quits **itself** before the script gets to
/// `brew upgrade`, so the cask's `uninstall quit:` — which Homebrew performs
/// with AppleScript — has nothing left to do. That keeps the whole upgrade off
/// the Automation grant: a disclaimed child would have made *brew* the
/// responsible process for that Apple event, and a menubar agent can't surface
/// the resulting permission prompt, so it would have failed silently.
@MainActor
enum BrewUpgradeRunner {

    static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/flow-bar")
    }
    static var scriptURL: URL { supportDir.appendingPathComponent("brew-upgrade.sh") }
    static var markerURL: URL { supportDir.appendingPathComponent("last-upgrade") }
    static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/flow-bar-upgrade.log")
    }

    /// Start the upgrade and quit so brew can replace the bundle.
    ///
    /// Returns false if the script could not even be launched, in which case
    /// the app stays up and the caller should report it — quitting on a failed
    /// launch would leave the user with nothing running and no explanation.
    @discardableResult
    static func start() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            // Rewritten every time rather than cached: the bundle path can
            // change (moved to /Applications, or run from a build directory).
            let body = BrewUpgrade.script(
                appPath: Bundle.main.bundlePath,
                bundleID: Bundle.main.bundleIdentifier ?? "cloud.facets.flow-bar",
                logPath: logURL.path,
                markerPath: markerURL.path,
                processMatch: "flow-bar.app/Contents/MacOS/flow-bar")
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            CLI.log("brew-upgrade: could not write script — \(error)")
            return false
        }

        // Clear any previous verdict so a stale "failed" can't be reported as
        // the outcome of this run.
        try? fm.removeItem(at: markerURL)

        guard CLI.spawnDetached(scriptURL.path, logPath: logURL.path) else {
            return false
        }

        // Quit on the next turn of the loop so the click finishes handling and
        // any open popover closes cleanly first.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    /// The outcome of the previous run, if one has been recorded. Consumes the
    /// marker, so a result is reported once and not on every launch.
    static func consumeLastResult() -> BrewUpgrade.Result? {
        guard let raw = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: markerURL)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrewUpgrade.Result(rawValue: value)
    }
}
