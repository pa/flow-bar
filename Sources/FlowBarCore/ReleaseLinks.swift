import Foundation

/// Where a version's release notes live.
///
/// The tag format (`v0.5.0`) is shared by the cask's source tarball URL, the
/// git tag, and this link — three places that must agree, and the only symptom
/// of them disagreeing is a 404 in a browser that nobody sees in a test run.
/// Building the URL in one tested function is cheaper than finding out.
public enum ReleaseLinks {
    public static let repo = "pa/flow-bar"

    public static var releasesURL: URL {
        URL(string: "https://github.com/\(repo)/releases")!
    }

    /// The release page for a version, or the index when there cannot be one.
    ///
    /// A local build stamps `0.0.0-dev` (`AppInfo.isDevBuild`) and a tag for it
    /// has never existed, so it goes to the index rather than a page that is
    /// guaranteed to 404.
    public static func url(forVersion version: String) -> URL {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("0.0.0") else { return releasesURL }
        // Tags carry the `v`; a version string may or may not.
        let tag = trimmed.hasPrefix("v") ? trimmed : "v\(trimmed)"
        guard let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://github.com/\(repo)/releases/tag/\(encoded)")
        else { return releasesURL }
        return url
    }
}
