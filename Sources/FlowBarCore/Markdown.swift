import Foundation

/// The list marker a `.listItem` block carries.
public enum MarkdownListKind: Equatable, Sendable {
    case bullet
    case ordered(Int)
    case checkbox(Bool)
}

/// One block-level element of a flow brief / update note.
///
/// Inline markup (bold, italic, `code`, links) is deliberately *not* parsed
/// here — it stays in the block's text and is handed to
/// `AttributedString(markdown:)` at render time. This type only answers "what
/// kind of block is this, and what is its content".
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, kind: MarkdownListKind, text: String)
    case code(language: String?, code: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// Block-level markdown parser for flow briefs and update notes.
///
/// Pure and dependency-free (CLAUDE.md: no third-party markdown engine), and
/// pure *data* — no AppKit, no SwiftUI — so the test harness can cover it.
/// Rendering lives in the app target (`MarkdownText`).
///
/// The one non-obvious rule is **soft-wrap joining**: flow's briefs are
/// hard-wrapped at ~72 columns, so a paragraph or list item spans several
/// source lines that must be re-joined into one run of text before layout.
/// Rendering each source line separately (what the old per-line renderer did)
/// double-wraps the text and is why briefs came out ragged.
public enum Markdown {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        // Pending soft-wrapped runs, flushed when a block boundary is hit.
        var para: [String] = []
        var quote: [String] = []

        func flushPara() {
            guard !para.isEmpty else { return }
            blocks.append(.paragraph(para.joined(separator: " ")))
            para = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            // A bare ">" line is a paragraph break inside the quote.
            var parts: [String] = []
            var run: [String] = []
            for q in quote {
                if q.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !run.isEmpty { parts.append(run.joined(separator: " ")); run = [] }
                } else {
                    run.append(q.trimmingCharacters(in: .whitespaces))
                }
            }
            if !run.isEmpty { parts.append(run.joined(separator: " ")) }
            quote = []
            guard !parts.isEmpty else { return }
            blocks.append(.quote(parts.joined(separator: "\n\n")))
        }
        func flushAll() { flushPara(); flushQuote() }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // --- fenced code -------------------------------------------------
            if let fence = fenceMarker(trimmed) {
                flushAll()
                let lang = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                i += 1
                var body: [String] = []
                var closed = false
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        closed = true
                        break
                    }
                    body.append(l)
                    i += 1
                }
                _ = closed   // an unterminated fence just runs to end of input
                blocks.append(.code(language: lang.isEmpty ? nil : lang,
                                    code: body.joined(separator: "\n")))
                continue
            }

            // --- blank -------------------------------------------------------
            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }

            // --- horizontal rule ---------------------------------------------
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            // --- table (header row + delimiter row) ---------------------------
            if trimmed.contains("|"), i + 1 < lines.count,
               isTableDelimiter(lines[i + 1]) {
                flushAll()
                let header = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(splitTableRow(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // --- heading ------------------------------------------------------
            if let h = heading(trimmed) {
                flushAll()
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // --- blockquote ---------------------------------------------------
            if trimmed.hasPrefix(">") {
                flushPara()
                var body = String(trimmed.dropFirst())
                if body.hasPrefix(" ") { body.removeFirst() }
                quote.append(body)
                i += 1
                continue
            }
            flushQuote()

            // --- list item (+ its soft-wrapped continuation lines) -------------
            if let item = listItem(raw) {
                flushPara()
                var text = item.text
                var j = i + 1
                while j < lines.count {
                    let nraw = lines[j]
                    let nt = nraw.trimmingCharacters(in: .whitespaces)
                    if nt.isEmpty { break }
                    if listItem(nraw) != nil { break }
                    if heading(nt) != nil || nt.hasPrefix(">") || isRule(nt)
                        || fenceMarker(nt) != nil { break }
                    // A continuation is indented past the item's own marker.
                    guard leadingSpaces(nraw) > item.spaces else { break }
                    text += " " + nt
                    j += 1
                }
                blocks.append(.listItem(indent: min(item.spaces / 2, 4),
                                        kind: item.kind, text: text))
                i = j
                continue
            }

            // --- paragraph ------------------------------------------------------
            para.append(trimmed)
            i += 1
        }

        flushAll()
        return blocks
    }

    // MARK: Line classifiers (pure, all unit-testable through `parse`)

    /// The fence run ("```" / "~~~~") opening a code block, else nil.
    static func fenceMarker(_ trimmed: String) -> String? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix { String($0) == ch }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    /// "### text" -> (3, "text"). Requires a space after the hashes.
    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count,
                rest.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces))
    }

    /// `---`, `***`, `___` (3+ of one char, nothing else). Table delimiter rows
    /// contain "|" so they never match.
    static func isRule(_ trimmed: String) -> Bool {
        let body = trimmed.filter { $0 != " " }
        guard body.count >= 3 else { return false }
        for ch in "-*_" where body.allSatisfy({ $0 == ch }) { return true }
        return false
    }

    /// A table's `|---|:--:|` separator row.
    static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split "| a | b |" into ["a", "b"], tolerating missing outer pipes.
    static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    /// "  - [x] text" -> (spaces: 2, kind: .checkbox(true), text: "text").
    static func listItem(_ raw: String) -> (spaces: Int, kind: MarkdownListKind, text: String)? {
        let spaces = leadingSpaces(raw)
        let body = raw.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        // Bullet markers: "- ", "* ", "+ "
        if let marker = ["- ", "* ", "+ "].first(where: { body.hasPrefix($0) }) {
            let rest = String(body.dropFirst(marker.count))
            for (box, done) in [("[x] ", true), ("[X] ", true), ("[ ] ", false)] {
                if rest.hasPrefix(box) {
                    return (spaces, .checkbox(done), String(rest.dropFirst(box.count)))
                }
            }
            return (spaces, .bullet, rest)
        }

        // Ordered markers: "1. " / "1) "
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = body.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")" {
                let rest = after.dropFirst()
                guard rest.hasPrefix(" ") else { return nil }
                return (spaces, .ordered(Int(digits) ?? 1),
                        String(rest.dropFirst()))
            }
        }
        return nil
    }
}
