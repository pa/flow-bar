import Foundation

/// The changelog, sliced into per-version sections.
///
/// `CHANGELOG.md` is already the source of truth — its top section is what
/// GitHub publishes as the release body when a version is tagged — so the app
/// reads the same text rather than keeping a second copy that can disagree with
/// the one people actually see. `build-app.sh` writes the top section into the
/// bundle, which is why "what's new" needs no network and cannot describe a
/// build other than the one running.
public enum ReleaseNotes {

    public struct Section: Equatable, Sendable {
        /// Without the leading `v`, so it compares to `CFBundleShortVersionString`.
        public var version: String
        /// The heading as written, e.g. `v0.5.0 — 2026-09-20`.
        public var heading: String
        /// Everything under the heading.
        public var body: String

        public init(version: String, heading: String, body: String) {
            self.version = version
            self.heading = heading
            self.body = body
        }

        /// Heading and body together, for rendering.
        public var markdown: String {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "# \(heading)" : "# \(heading)\n\n\(text)"
        }
    }

    /// The newest section — the one a release publishes.
    public static func top(of changelog: String) -> Section? {
        sections(of: changelog).first
    }

    /// A specific version's section, if the changelog still carries it.
    public static func section(version: String, in changelog: String) -> Section? {
        let wanted = normalise(version)
        return sections(of: changelog).first { $0.version == wanted }
    }

    /// Every `## ` section, newest first.
    public static func sections(of changelog: String) -> [Section] {
        var out: [Section] = []
        var heading: String?
        var body: [String] = []

        func flush() {
            guard let heading else { return }
            out.append(Section(version: normalise(firstToken(of: heading)),
                               heading: heading,
                               body: body.joined(separator: "\n")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for line in changelog.components(separatedBy: .newlines) {
            // `## ` only: `### ` is a subsection inside a release ("### Added")
            // and swallowing those would cut every entry into fragments.
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
            } else if heading != nil {
                body.append(line)
            }
        }
        flush()
        return out
    }

    /// The version token of a heading: `v0.5.0 — 2026-09-20` → `v0.5.0`.
    static func firstToken(of heading: String) -> String {
        heading.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? heading
    }

    /// Tags carry a `v`; `CFBundleShortVersionString` does not.
    static func normalise(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }
}
