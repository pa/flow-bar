import Foundation

/// The self-upgrade flow for a Homebrew source install.
///
/// ## Why the app can't just install the zip
///
/// The in-app updater downloads a CI-built zip and swaps the bundle. That is
/// correct for people who installed the `.dmg`/`.zip`, and wrong three ways for
/// a source install — two of them silently:
///
/// 1. **The Automation grant dies.** TCC keys the grant to the bundle's
///    Designated Requirement. Source installs are signed with a *per-machine*
///    identity (`scripts/create-signing-cert.sh`); the released zip is signed
///    with CI's own persistent cert. Swapping one for the other changes the DR,
///    so macOS drops the grant and `flow do` starts failing with -1743 and no
///    message. It would also thrash: the next `brew upgrade` signs locally
///    again and drops it a second time.
/// 2. **The UI stops being native.** CI builds on `macos-15`, so the zip links
///    against that SDK. SwiftUI takes its appearance from the SDK a binary was
///    linked against, so installing it on a newer macOS silently reverts the
///    app to compatibility rendering — the exact bug the source-build cask
///    exists to prevent.
/// 3. **Homebrew's receipt goes stale**, so brew and the app disagree about
///    what is installed and start fighting.
///
/// ## So it delegates instead of downloading
///
/// Clicking Update runs `brew upgrade` in a detached shell. That compiles
/// locally (native SDK), re-signs with *this machine's* identity (the grant
/// survives), and leaves Homebrew's receipt correct — while still being one
/// click. The command has to outlive the app, because the cask's
/// `uninstall quit:` kills it partway through; the script relaunches it at the
/// end, which doubles as the "it worked" signal.
public enum BrewUpgrade {

    /// Our Homebrew tap, as `brew` names it.
    public static let tap = "pa/flow-bar"
    public static let cask = "flow-bar"

    /// Where the detached script reports what happened. The app reads this on
    /// its next launch, since it isn't running when the result is known.
    public enum Result: String, Sendable {
        case ok
        case failed
    }

    /// The command a user can run by hand, and what the script does.
    ///
    /// **The tap refresh is not optional.** flow-bar lives in a third-party tap,
    /// and `brew upgrade` only sees a new version once that tap's checkout has
    /// been pulled. `brew upgrade` normally does that via auto-update — but not
    /// within `HOMEBREW_AUTO_UPDATE_SECS` (24h) of the last one, nor with
    /// `HOMEBREW_NO_AUTO_UPDATE` set. Verified: with a stale tap,
    /// `brew outdated --cask flow-bar` reported *nothing* while 0.4.0 was
    /// already published; after pulling the tap it reported
    /// `flow-bar (0.3.1) != 0.4.0`.
    ///
    /// Pulling the one tap rather than `brew update` keeps it quick — update
    /// refreshes every tap and homebrew-core too — and is the same fast-forward
    /// update would have done.
    public static let manualCommand =
        "git -C \"$(brew --repository \(tap))\" pull --ff-only && brew upgrade --cask \(cask)"

    /// The detached upgrade script.
    ///
    /// - Parameters:
    ///   - appPath: the installed bundle, relaunched at the end.
    ///   - bundleID: fallback for relaunching if the path moved.
    ///   - logPath: everything the script does, appended.
    ///   - markerPath: one word, `ok` or `failed`, read by the app next launch.
    ///   - processMatch: `pgrep -f` pattern for waiting out the old app.
    public static func script(appPath: String,
                              bundleID: String,
                              logPath: String,
                              markerPath: String,
                              processMatch: String) -> String {
        """
        #!/bin/sh
        # flow-bar self-upgrade. Written and launched by flow-bar; safe to delete.
        #
        # Runs DETACHED and in its own session, because the cask's
        # `uninstall quit:` stops the app that started it. Being orphaned is the
        # normal case here, not an error.
        set -u

        # A GUI-launched parent passes almost no PATH, and brew is the whole
        # point of this script.
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        export PATH

        LOG=\(shellQuote(logPath))
        MARKER=\(shellQuote(markerPath))
        APP=\(shellQuote(appPath))

        mkdir -p "$(dirname "$LOG")" "$(dirname "$MARKER")" 2>/dev/null || true
        exec >>"$LOG" 2>&1
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') upgrade starting ==="

        # flow-bar quits itself before launching this, so brew's AppleScript
        # `quit` has nothing to do — which is what keeps this off the Automation
        # grant entirely. Wait for the process to actually be gone first.
        n=0
        while pgrep -f \(shellQuote(processMatch)) >/dev/null 2>&1 && [ "$n" -lt 30 ]; do
            sleep 0.5
            n=$((n + 1))
        done
        if [ "$n" -ge 30 ]; then
            echo "warning: old app still running after 15s; continuing anyway"
        fi

        if ! command -v brew >/dev/null 2>&1; then
            echo "error: brew not found on PATH ($PATH)"
            printf 'failed' > "$MARKER"
            open -a "$APP" 2>/dev/null || open -b \(shellQuote(bundleID)) 2>/dev/null || true
            exit 1
        fi

        # Refresh just our tap. `brew upgrade` can't see a new version until the
        # tap's git checkout is pulled, and auto-update may legitimately skip it.
        TAP_REPO="$(brew --repository \(shellQuote(tap)) 2>/dev/null || true)"
        if [ -n "$TAP_REPO" ] && [ -d "$TAP_REPO/.git" ]; then
            echo "--- refreshing tap $TAP_REPO"
            git -C "$TAP_REPO" pull --ff-only || echo "warning: tap pull failed; continuing"
        else
            echo "warning: tap \(tap) not found as a git checkout; continuing"
        fi

        echo "--- brew upgrade --cask \(cask)"
        if brew upgrade --cask \(cask); then
            echo "=== upgrade ok"
            printf 'ok' > "$MARKER"
        else
            # Leave whatever bundle is on disk alone — a failed cask upgrade
            # keeps the old one, so relaunching still gives a working app.
            echo "=== upgrade FAILED"
            printf 'failed' > "$MARKER"
        fi

        # Relaunching is both the recovery and the progress signal: the app
        # coming back is how the user learns it finished.
        open -a "$APP" 2>/dev/null || open -b \(shellQuote(bundleID)) 2>/dev/null \\
            || echo "error: could not relaunch flow-bar"
        """
    }

    /// Single-quote a string for POSIX sh.
    ///
    /// Paths here come from `NSHomeDirectory()` and a bundle path, so a space is
    /// entirely possible ("Application Support") and an apostrophe is not
    /// impossible in a user's home directory name.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
