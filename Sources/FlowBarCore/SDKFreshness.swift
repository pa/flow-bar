import Foundation

/// Whether it is worth telling someone to rebuild the app.
///
/// **The useful question is not "is this build behind the OS?" but "would
/// rebuilding change anything?"** Those differ for months at a time: Apple
/// ships a new macOS before the Xcode that carries its SDK, so a user who
/// upgrades early has an OS newer than any SDK on their machine. Asking that
/// user to rebuild produces an identical binary and the prompt returns — advice
/// that cannot be taken is worse than silence, because it teaches people to
/// ignore the footer.
///
/// Measured: macOS 27.0 with the newest available SDK at 26.5, and a 26.5
/// build, showed "Rebuild for macOS 27" permanently.
public enum SDKFreshness {

    /// Major version from a version string like `26.5`.
    public static func major(_ version: String?) -> Int? {
        guard let version, let first = version.split(separator: ".").first else { return nil }
        return Int(first)
    }

    /// Whether to nudge for a rebuild.
    ///
    /// Both halves have to hold:
    /// - the OS is newer than what this binary was built against, so the UI is
    ///   actually rendering in compatibility mode, and
    /// - a newer SDK exists on this machine, so a rebuild would pick it up.
    ///
    /// When the available SDK can't be determined — no toolchain, `xcrun`
    /// missing — the answer is no. Someone with no toolchain cannot rebuild
    /// anyway, and guessing turns the nudge into noise.
    public static func shouldRebuild(buildSDK: String?, availableSDK: String?,
                                     osMajor: Int) -> Bool {
        guard let built = major(buildSDK) else { return false }
        guard osMajor > built else { return false }
        guard let available = major(availableSDK) else { return false }
        return available > built
    }
}
