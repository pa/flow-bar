import AppKit
import FlowBarCore
import SwiftUI

/// Renders a flow brief / update note as rich text.
///
/// **Why an `NSTextView` and not a stack of SwiftUI `Text`s.** SwiftUI's
/// `.textSelection(.enabled)` selects within *one* `Text` view — a drag can
/// never span two of them. The old renderer emitted one `Text` per source
/// line, so selection covered a single line and stopped. Backing the whole
/// pane with a single text view is the only way to get a drag that runs from
/// the first paragraph, through a code block, and out the other side; it also
/// brings real link handling, `⌘C` that keeps formatting, and the system
/// Look Up / Services menu for free.
///
/// The trade this makes (chosen deliberately — see the task brief): a fenced
/// code block is a full-width tinted `NSTextTableBlock` that **wraps** rather
/// than scrolling horizontally, because a text view cannot host an
/// independently-scrolling sub-region.
///
/// Block structure comes from `Markdown.parse` in FlowBarCore (pure, tested);
/// everything here is presentation.
struct MarkdownText: NSViewRepresentable {
    let source: String
    /// A live find: every match is highlighted in place. Empty means no find.
    var find: String = ""

    init(_ source: String, find: String = "") {
        self.source = source
        self.find = find
    }

    func makeNSView(context: Context) -> MarkdownNSTextView {
        let v = MarkdownNSTextView()
        v.setMarkdown(source, find: find)
        return v
    }

    func updateNSView(_ nsView: MarkdownNSTextView, context: Context) {
        nsView.setMarkdown(source, find: find)
    }

    /// SwiftUI asks for the height at a proposed width; the text view lays out
    /// at that width and reports what it used. Without this the view collapses
    /// or overflows inside the enclosing `ScrollView`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownNSTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width < .infinity else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// A non-editable, selectable text view built on an explicit TextKit 1 stack.
///
/// TextKit 1 is deliberate: `NSTextTable` (which draws the code-block and
/// table cells) and `NSLayoutManager.usedRect(for:)` — the height measurement
/// `sizeThatFits` depends on — are both TextKit 1 facilities. Letting
/// `NSTextView` pick TextKit 2 loses `layoutManager` entirely.
final class MarkdownNSTextView: NSTextView {
    private var rendered: String?
    private var highlighted: String?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        allowsUndo = false
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        displaysLinkToolTips = true
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Every range the current find matched, in document order.
    private(set) var matchRanges: [NSRange] = []
    private var currentMatch = -1

    /// The rendered document with no find applied.
    ///
    /// **Kept so a find doesn't re-parse the markdown on every keystroke.** The
    /// highlight cannot simply be stripped off the live storage —
    /// `removeAttribute(.backgroundColor)` would take the renderer's own code
    /// block and table cell backgrounds with it — so each new query starts from
    /// a clean copy. Copying an attributed string is cheap; parsing a 17 KB
    /// changelog eight times while someone types "palette" is not.
    private var base: NSAttributedString?

    func setMarkdown(_ source: String, find: String = "", current: Int = 0) {
        if rendered != source {
            rendered = source
            base = MarkdownRenderer.attributed(source)
            highlighted = nil
        }
        if highlighted != find {
            highlighted = find
            guard let base else { return }
            let text = NSMutableAttributedString(attributedString: base)
            matchRanges = find.isEmpty ? [] : Self.highlight(find, in: text)
            textStorage?.setAttributedString(text)
            currentMatch = -1
        }
        focusMatch(current)
    }

    /// Mark one match as the current one and scroll it into view.
    ///
    /// This is the half of a find that a highlight alone cannot do: on a brief
    /// longer than the panel, every match but the first is off-screen, and a
    /// count with no way to reach what it counted is a tease.
    private func focusMatch(_ index: Int) {
        guard !matchRanges.isEmpty, let storage = textStorage else { return }
        let i = min(max(index, 0), matchRanges.count - 1)
        guard i != currentMatch else { return }
        currentMatch = i
        storage.beginEditing()
        for (n, range) in matchRanges.enumerated() where range.upperBound <= storage.length {
            storage.addAttribute(.backgroundColor,
                                 value: n == i ? Self.currentColour : Self.matchColour,
                                 range: range)
        }
        storage.endEditing()
        scrollToMatch(matchRanges[i])
    }

    /// Bring a match into view.
    ///
    /// **Not `scrollRangeToVisible`.** That asks the layout manager where a
    /// range is, and the answer is only meaningful once the range has been laid
    /// out — on a brief longer than the panel, everything below the fold has
    /// not been, so it scrolls nowhere. Forcing layout first is the fix, and
    /// while we are here the rect gets padded so the match lands *inside* the
    /// view rather than flush against its edge, where you would still have to
    /// scroll to read the line it is on.
    private func scrollToMatch(_ range: NSRange) {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        // Roughly three lines of air either side.
        rect = rect.insetBy(dx: 0, dy: -56)
        // After the current layout pass: scrolling mid-pass is a no-op when the
        // geometry it depends on is what the pass is still deciding.
        DispatchQueue.main.async { [weak self] in self?.scrollToVisible(rect) }
    }

    /// Every other match, and the one you are on. Two colours because "12
    /// matches" is only useful if you can tell which one you are looking at.
    static let matchColour = NSColor.systemYellow.withAlphaComponent(0.28)
    static let currentColour = NSColor.systemOrange.withAlphaComponent(0.75)

    /// Light up the query's matches in place.
    ///
    /// **Measured against the RENDERED text, not the markdown source.** The two
    /// differ — `## ` is gone, `**bold**` has lost its asterisks — so offsets
    /// taken from the source would drift a little further out of place with
    /// every marker above them. Searching the string that is actually on screen
    /// means there is nothing to map.
    ///
    /// The whole attributed string is rebuilt for each new query rather than
    /// having the last highlight stripped off: `removeAttribute(.backgroundColor)`
    /// would also take the renderer's own backgrounds (code blocks, table
    /// cells) with it, and a brief is a few kilobytes — cheap to render again.
    @discardableResult
    private static func highlight(_ query: String,
                                  in text: NSMutableAttributedString) -> [NSRange] {
        let plain = text.string
        let offsets = DocumentSearch.matchOffsets(query, in: plain)
        guard !offsets.isEmpty else { return [] }

        // Character offsets → UTF-16, which is what NSRange counts in.
        var utf16Start: [Int] = []
        utf16Start.reserveCapacity(plain.count + 1)
        var acc = 0
        for ch in plain {
            utf16Start.append(acc)
            acc += ch.utf16.count
        }
        utf16Start.append(acc)

        var ranges: [NSRange] = []
        for run in DocumentSearch.runs(offsets) {
            guard run.lowerBound < utf16Start.count, run.upperBound < utf16Start.count else { continue }
            let location = utf16Start[run.lowerBound]
            let length = utf16Start[run.upperBound] - location
            guard length > 0, location + length <= text.length else { continue }
            let range = NSRange(location: location, length: length)
            text.addAttribute(.backgroundColor, value: matchColour, range: range)
            ranges.append(range)
        }
        return ranges
    }

    /// Lay out at `width` and report the height used.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    /// Let the enclosing SwiftUI `ScrollView` handle the wheel — when sized to
    /// its full content, the text view never scrolls itself. Inside a real
    /// `NSScrollView` (`MarkdownDocument`) it does, so the wheel stays put.
    override func scrollWheel(with event: NSEvent) {
        if enclosingScrollView != nil { super.scrollWheel(with: event) }
        else { nextResponder?.scrollWheel(with: event) }
    }
}

/// A whole document — brief plus notes — in **one scrolling text view**.
///
/// `MarkdownText` is sized to its content and scrolled by whatever SwiftUI
/// container holds it, which is right for a pane made of several blocks and
/// wrong for a find: `scrollRangeToVisible` needs a text view that owns its own
/// scrolling, and a `ScrollViewReader` can only scroll to a view's id, never to
/// a line inside one. So the palette's brief is a single view over the whole
/// document, which is also what makes ⌘-dragging a selection across the brief
/// and into a note work.
struct MarkdownDocument: NSViewRepresentable {
    let source: String
    var find: String = ""
    /// Which match is the current one.
    var current: Int = 0
    /// How many matches the find turned up — reported back because only the
    /// rendered text knows.
    var onMatchCount: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        // The geometry a hosted text view needs and does not have by default: a
        // real starting frame, an unbounded height to grow into, and a container
        // that tracks its width. Without these it has no scrollable extent, so
        // `scrollToVisible` has nowhere to go and the find silently stops
        // scrolling — which is exactly how this shipped broken.
        let text = MarkdownNSTextView()
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        text.setMarkdown(source, find: find, current: current)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? MarkdownNSTextView else { return }
        // The clip view's width is only known after layout, and the text view
        // has to follow it or the container wraps at the wrong width.
        let width = scroll.contentSize.width
        if width > 0, abs(text.frame.width - width) > 0.5 {
            text.frame.size.width = width
            text.textContainer?.containerSize = NSSize(width: width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        }
        text.setMarkdown(source, find: find, current: current)
        let count = text.matchRanges.count
        // Reporting during an update would mutate state mid-render.
        DispatchQueue.main.async { onMatchCount(count) }
    }
}

/// Turns `[MarkdownBlock]` into one `NSAttributedString`.
enum MarkdownRenderer {
    // Sizes match the old per-line renderer so the peek's density is unchanged.
    private static let bodySize: CGFloat = 14
    private static var body: NSFont { .systemFont(ofSize: bodySize) }
    private static var mono: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }

    private static var codeFill: NSColor { NSColor(white: 1, alpha: 0.05) }
    private static var codeStroke: NSColor { NSColor(white: 1, alpha: 0.10) }
    private static var inlineCodeFill: NSColor { NSColor(white: 1, alpha: 0.09) }

    static func attributed(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in Markdown.parse(source) {
            out.append(render(block))
        }
        // Trailing newline from the last block would add a blank line of height.
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    // MARK: Blocks

    private static func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15 : 14)
            let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
            let style = paragraph(spacingBefore: level <= 2 ? 8 : 6, spacingAfter: 3)
            return paragraphRun(inline(text, font: .systemFont(ofSize: size, weight: weight),
                                       color: .labelColor),
                                style: style)

        case .paragraph(let text):
            return paragraphRun(inline(text, font: body, color: .labelColor),
                                style: paragraph(spacingAfter: 6))

        case .listItem(let indent, let kind, let text):
            return listItem(indent: indent, kind: kind, text: text)

        case .code(_, let code):
            return codeBlock(code)

        case .quote(let text):
            return quoteBlock(text)

        case .table(let header, let rows):
            return tableBlock(header: header, rows: rows)

        case .rule:
            return ruleBlock()
        }
    }

    private static func listItem(indent: Int, kind: MarkdownListKind,
                                 text: String) -> NSAttributedString {
        let base = CGFloat(indent) * 16
        let gutter: CGFloat = 18
        let style = paragraph(spacingAfter: 3)
        style.firstLineHeadIndent = base
        style.headIndent = base + gutter
        style.tabStops = [NSTextTab(textAlignment: .left, location: base + gutter)]

        let marker: NSAttributedString
        switch kind {
        case .bullet:
            marker = NSAttributedString(string: "•\t", attributes: [
                .font: body, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .ordered(let n):
            marker = NSAttributedString(string: "\(n).\t", attributes: [
                .font: body, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .checkbox(let done):
            marker = NSAttributedString(string: (done ? "☑" : "☐") + "\t", attributes: [
                .font: body,
                .foregroundColor: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ])
        }

        let line = NSMutableAttributedString()
        line.append(marker)
        line.append(inline(text, font: body, color: .labelColor))
        return paragraphRun(line, style: style)
    }

    /// A fenced block: every line shares ONE `NSTextTableBlock`, which is what
    /// merges them into a single tinted, padded cell.
    private static func codeBlock(_ code: String) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                    startingColumn: 0, columnSpan: 1)
        cell.setContentWidth(100, type: .percentageValueType)
        cell.backgroundColor = codeFill
        cell.setBorderColor(codeStroke)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setWidth(8, type: .absoluteValueType, for: .padding)

        let out = NSMutableAttributedString()
        let lines = code.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.textBlocks = [cell]
            style.lineBreakMode = .byWordWrapping
            // A wrapped code line hangs under its own start, so continuation
            // reads as continuation rather than as a new statement.
            style.headIndent = 14
            if idx == 0 { style.paragraphSpacingBefore = 6 }
            if idx == lines.count - 1 { style.paragraphSpacing = 8 }
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: mono,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]))
        }
        return out
    }

    private static func quoteBlock(_ text: String) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                    startingColumn: 0, columnSpan: 1)
        cell.setContentWidth(100, type: .percentageValueType)
        cell.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        cell.setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.7), for: .minX)
        cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
        cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)

        let out = NSMutableAttributedString()
        let paras = text.components(separatedBy: "\n\n")
        for (idx, p) in paras.enumerated() {
            let style = NSMutableParagraphStyle()
            style.textBlocks = [cell]
            if idx == 0 { style.paragraphSpacingBefore = 4 }
            if idx == paras.count - 1 { style.paragraphSpacing = 8 }
            let line = NSMutableAttributedString()
            line.append(inline(p, font: body, color: .secondaryLabelColor))
            line.append(newline(like: line))
            line.addAttribute(.paragraphStyle, value: style,
                              range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private static func tableBlock(header: [String], rows: [[String]]) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        let out = NSMutableAttributedString()
        let allRows = [header] + rows
        for (r, row) in allRows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                cell.setBorderColor(codeStroke)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                if r == 0 { cell.backgroundColor = codeFill }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                if r == 0 { style.paragraphSpacingBefore = 6 }
                if r == allRows.count - 1 { style.paragraphSpacing = 8 }

                let text = c < row.count ? row[c] : ""
                let font = r == 0 ? NSFont.systemFont(ofSize: bodySize - 1, weight: .semibold)
                                  : NSFont.systemFont(ofSize: bodySize - 1)
                let line = NSMutableAttributedString()
                line.append(inline(text, font: font,
                                   color: r == 0 ? .secondaryLabelColor : .labelColor))
                // An empty cell still needs a terminator with a real font.
                line.append(line.length > 0 ? newline(like: line)
                                            : NSAttributedString(string: "\n", attributes: [.font: font]))
                line.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0, length: line.length))
                out.append(line)
            }
        }
        return out
    }

    /// A `---` rule: a thin full-width cell with only a top border.
    private static func ruleBlock() -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                    startingColumn: 0, columnSpan: 1)
        cell.setContentWidth(100, type: .percentageValueType)
        cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        cell.setBorderColor(codeStroke, for: .minY)

        let style = NSMutableParagraphStyle()
        style.textBlocks = [cell]
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 8
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 2),
            .paragraphStyle: style,
        ])
    }

    // MARK: Helpers

    private static func paragraph(spacingBefore: CGFloat = 0,
                                  spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func paragraphRun(_ text: NSAttributedString,
                                     style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.append(newline(like: text))
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A paragraph-terminating newline carrying the run's own font.
    ///
    /// An unattributed "\n" falls back to the attributed-string default
    /// (Helvetica 12), and because the terminator belongs to the last line
    /// fragment it drags that line's metrics with it. Inheriting the trailing
    /// attributes keeps every line's height derived from the text it shows.
    private static func newline(like text: NSAttributedString) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if text.length > 0 {
            attrs = text.attributes(at: text.length - 1, effectiveRange: nil)
            attrs[.link] = nil            // never extend a link over the break
            attrs[.underlineStyle] = nil
            attrs[.backgroundColor] = nil // nor an inline-code highlight
        }
        if attrs[.font] == nil { attrs[.font] = body }
        return NSAttributedString(string: "\n", attributes: attrs)
    }

    /// Inline markdown (bold / italic / `code` / links) for one block's text.
    ///
    /// `AttributedString(markdown:)` reports emphasis as
    /// `inlinePresentationIntent` — a semantic marker SwiftUI's `Text`
    /// understands but AppKit does not. So each run's intent is translated
    /// into a concrete `NSFont` here; without this every run would render at
    /// the base weight and the emphasis would silently vanish.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let plain = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ])
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return linkify(plain)
        }

        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            guard !piece.isEmpty else { continue }
            var runFont = font
            var runColor = color
            var attrs: [NSAttributedString.Key: Any] = [:]

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { runFont = with(runFont, .bold) }
                if intent.contains(.emphasized) { runFont = with(runFont, .italic) }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = inlineCodeFill
                }
            }
            if let link = run.link {
                attrs[.link] = link
                runColor = .linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attrs[.font] = runFont
            attrs[.foregroundColor] = runColor
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return linkify(out)
    }

    /// Make bare `https://…` URLs clickable. Markdown syntax covers `[x](y)`
    /// and `<y>`; briefs also just paste a URL inline.
    private static func linkify(_ text: NSAttributedString) -> NSAttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              !text.string.isEmpty else { return text }
        let full = NSRange(location: 0, length: (text.string as NSString).length)
        let matches = detector.matches(in: text.string, range: full)
        guard !matches.isEmpty else { return text }

        let out = NSMutableAttributedString(attributedString: text)
        for m in matches {
            guard let url = m.url,
                  out.attribute(.link, at: m.range.location, effectiveRange: nil) == nil
            else { continue }
            out.addAttributes([
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: m.range)
        }
        return out
    }

    private static func with(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor
            .withSymbolicTraits(descriptor(font).union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func descriptor(_ font: NSFont) -> NSFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }
}
