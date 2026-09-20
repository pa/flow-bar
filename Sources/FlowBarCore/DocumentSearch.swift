import Foundation

/// Find-in-document: which characters of a brief the query matched, so they can
/// be **highlighted where they are**.
///
/// It returns offsets, not results. A brief is a document you are reading, and a
/// find inside one should light the words up in place — replacing the document
/// with a list of matching lines answers a question nobody asked ("where else
/// does this word appear") instead of the one they did ("show me this word").
///
/// Matching runs the same ladder as the result list (`PaletteMatcher`), line by
/// line, so there is one fuzzy-find implementation in the app.
///
/// **What "fuzzy" can honestly mean in prose.** A scattered subsequence is the
/// right rule for a slug — `fbn` → `flow-bar-notch` is what you meant — and the
/// wrong one for a paragraph, because the letters of any short word occur
/// somewhere in any long sentence. So a document match must also be **compact**:
/// see `spanLimit`.
public enum DocumentSearch {

    /// How far a scattered match may stretch, for a query of `n` characters.
    ///
    /// **n + 4, and the slack is deliberately small.** A fuzzy hit in prose
    /// should be "the word you meant, missing a few characters" — room for a
    /// hyphen, a dropped vowel, a plural. Measured on a real brief, a limit of
    /// 3n let `rail` match "**Ra**nk**i**ng is a **l**adder" across fourteen
    /// characters, which is how a find turns into noise.
    ///
    /// The accepted cost is that an acronym of a *phrase* doesn't match here —
    /// `sfp` will not find "Search-first popover" the way `fbn` finds
    /// `flow-bar-notch`. That is the same slug/prose split the matcher already
    /// makes: a slug is one token you abbreviate, a sentence is not. The exact,
    /// prefix, word-prefix and substring rungs are untouched and do the work.
    public static func spanLimit(for token: String) -> Int { token.count + 4 }

    /// Character offsets into `text` that the query matched.
    ///
    /// Matching is per **line**: a whitespace-separated query is AND within one
    /// line, so two words narrow the document instead of lighting up every
    /// paragraph containing either. Offsets are absolute, sorted, and index
    /// `text` by `Character` — the caller converts to whatever its text system
    /// counts in.
    public static func matchOffsets(_ query: String, in text: String) -> [Int] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var out: [Int] = []
        let chars = Array(text)
        var start = 0
        // `Character.isNewline` treats CRLF as one character, so walking the
        // array keeps the offsets honest whatever the line endings are.
        for i in 0...chars.count where i == chars.count || chars[i].isNewline {
            if i > start {
                let line = String(chars[start..<i])
                var lineOffsets: [Int] = []
                var matchedAll = true
                for token in tokens {
                    guard let hit = PaletteMatcher.score(token, in: line,
                                                         maxSpan: spanLimit(for: token)) else {
                        matchedAll = false
                        break
                    }
                    lineOffsets.append(contentsOf: hit.offsets)
                }
                if matchedAll { out.append(contentsOf: lineOffsets.map { $0 + start }) }
            }
            start = i + 1
        }
        return Array(Set(out)).sorted()
    }

    /// Whether the query finds anything at all — the one thing a highlight
    /// cannot say for itself, because "no matches" and "not looking" render
    /// identically.
    public static func matches(_ query: String, in text: String) -> Bool {
        !matchOffsets(query, in: text).isEmpty
    }

    /// Offsets folded into runs, which is what a text system wants: one
    /// attribute per highlighted word, not one per letter.
    ///
    /// **Gaps of up to `mergingGapsUpTo` characters are swallowed.** A fuzzy
    /// match has holes in it by definition — `matchr` matches "matcher" with the
    /// `e` left over — and highlighting `match` and `r` while leaving one letter
    /// dark in the middle of a word reads as a rendering bug, not as precision.
    /// The span limit already guarantees the whole match is compact, so filling
    /// the holes lights the word you found rather than the letters you typed.
    public static func runs(_ offsets: [Int], mergingGapsUpTo gap: Int = 2) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < offsets.count {
            var j = i
            while j + 1 < offsets.count, offsets[j + 1] - offsets[j] <= gap + 1 { j += 1 }
            out.append(offsets[i]..<(offsets[j] + 1))
            i = j + 1
        }
        return out
    }
}
