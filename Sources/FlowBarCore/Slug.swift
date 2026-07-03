import Foundation

/// Derive a short, ASCII, kebab-case slug from a name (for `--slug`).
/// Lowercase, non-alphanumerics become separators, collapsed to single dashes,
/// capped at `maxWords` words. "Add OAuth login!" -> "add-oauth-login".
public func slugify(_ name: String, maxWords: Int = 6) -> String {
    let mapped = name.lowercased().map { ch -> Character in
        (ch.isLetter || ch.isNumber) ? ch : " "
    }
    let words = String(mapped).split(separator: " ").prefix(maxWords)
    return words.joined(separator: "-")
}
