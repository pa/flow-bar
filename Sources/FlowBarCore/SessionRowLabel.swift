import Foundation

/// How a session row names the thing it is pointing at.
///
/// **The slug leads.** It is what you type, what you search on, and the only
/// string `flow do` accepts — so a row labelled by task name makes you translate
/// before you can act on it. The name is the *subtitle*: useful when it says
/// something the slug doesn't, and noise when it doesn't.
///
/// Pure string logic, deliberately outside the app target, so the harness can
/// prove the "does this name earn its line?" rule without a view.
public enum SessionRowLabel {

    /// Words flow puts into a synthetic task name that carry no information of
    /// their own. `flow run playbook ms-update` names its run task
    /// "ms-update run ms-update--2026-09-16-06-41" — every token of which is
    /// already on the first line except "run".
    static let fillerWords: Set<String> = ["run", "task"]

    /// The second line for a row, or nil when the name earns no line.
    ///
    /// Earns a line when it contributes at least one alphanumeric token the
    /// slug does not already carry. That keeps a real title
    /// ("flow-bar-attention" → "opening permissions, session-alert coverage")
    /// and drops the restatements: a task named after its own slug, and every
    /// playbook run, whose name is the run slug with "run" in front of it.
    public static func secondary(slug: String, name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slugTokens = Set(tokens(slug))
        let novel = tokens(trimmed).filter {
            !slugTokens.contains($0) && !fillerWords.contains($0)
        }
        return novel.isEmpty ? nil : trimmed
    }

    /// Lowercase alphanumeric runs. Splitting on everything else means `-`, `_`,
    /// `:` and `—` are all just separators, so "flow-bar" and "flow bar" compare
    /// equal — which is the point: the slug's punctuation is a naming
    /// convention, not content.
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
