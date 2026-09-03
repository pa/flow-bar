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
    /// i.e. the UI is rendering in compatibility mode and a rebuild would fix it.
    static var sdkIsBehindOS: Bool {
        guard let built = buildSDKMajor else { return false }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion > built
    }
}
