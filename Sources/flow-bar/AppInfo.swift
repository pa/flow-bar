import FlowBarCore
import Foundation

/// Build-time facts stamped into Info.plist by `build-app.sh`.
///
/// These describe *how this bundle got here*, which decides two things the app
/// can't otherwise know: whether it is allowed to update itself (Updater), and
/// whether it should be locally signed (SelfSign).
///
/// Stamped into the plist rather than a sidecar file so the answer survives the
/// bundle being copied or moved — a path check can't tell a Homebrew cask
/// install in /Applications from a manual DMG install in the same place.
enum AppInfo {
    /// How this build was installed.
    ///   `homebrew-source` — compiled on this machine by the cask. Updates are
    ///                       Homebrew's job; self-installing would replace an
    ///                       SDK-native binary with a CI-built one.
    ///   `github-release`  — a prebuilt download. Self-updates normally.
    ///   `dev`             — a local `./build-app.sh`.
    static var channel: String {
        Bundle.main.infoDictionary?["FBInstallChannel"] as? String ?? "dev"
    }

    /// macOS SDK this binary was linked against, e.g. "26.5". SwiftUI picks its
    /// appearance from the SDK, not the running OS, so a build made on an older
    /// SDK keeps rendering in compatibility mode forever — this is what lets us
    /// notice and tell the user to rebuild.
    static var buildSDK: String? {
        Bundle.main.infoDictionary?["FBBuildSDK"] as? String
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    /// This build's release notes — the top CHANGELOG section, written into the
    /// bundle by `build-app.sh`.
    ///
    /// Nil for a `swift run` build, which has no bundle to read from: the notes
    /// are a property of a *packaged* app, and inventing them from the repo at
    /// runtime would describe a version that is not what is running.
    /// The bundled changelog, whole.
    static var changelog: String? {
        guard let url = Bundle.main.url(forResource: "release-notes", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// The newest section — what this build's release announced.
    static var releaseNotesSection: ReleaseNotes.Section? {
        changelog.flatMap { ReleaseNotes.top(of: $0) }
    }

    /// Whether the bundled notes actually describe the running build.
    ///
    /// They are produced by two independent steps — `build-app.sh` stamps the
    /// version, and a human writes the changelog entry — so they can disagree,
    /// and the failure is silent: the app would announce "What's new in v0.5.0"
    /// and then show v0.4.3's notes. Announcing is gated on them matching.
    static var releaseNotesMatchBuild: Bool {
        releaseNotesSection?.version == version
    }

    /// True when Homebrew owns this install and the in-app updater must stand down.
    static var isManagedInstall: Bool { channel == "homebrew-source" }

    /// An untagged local build. Its version is a placeholder, so update checks
    /// would always report "newer available" — suppress them.
    static var isDevBuild: Bool { version.hasPrefix("0.0.0") }

    /// Major version of the SDK this was built against, if known.
    static var buildSDKMajor: Int? {
        buildSDK.flatMap { Int($0.split(separator: ".").first.map(String.init) ?? "") }
    }

    /// Set when the running OS is newer than the SDK we were built against —
    /// i.e. the UI is rendering in compatibility mode.
    ///
    /// **Not on its own a reason to ask for a rebuild**: Apple ships a new macOS
    /// months before the Xcode carrying its SDK, so this is true for everyone
    /// who upgrades early and a rebuild would produce an identical binary. See
    /// `SDKFreshness.shouldRebuild`, which also asks whether a newer SDK exists.
    static var sdkIsBehindOS: Bool {
        guard let built = buildSDKMajor else { return false }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion > built
    }

    /// The newest macOS SDK this machine can build against, or nil when there is
    /// no usable toolchain.
    ///
    /// Asked for the `macosx` SDK by name for the same reason `build-app.sh`
    /// does: with Xcode selected, a bare `xcrun --show-sdk-version` can resolve
    /// to the Command Line Tools SDK instead.
    static func availableSDKVersion() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["--sdk", "macosx", "--show-sdk-version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}
