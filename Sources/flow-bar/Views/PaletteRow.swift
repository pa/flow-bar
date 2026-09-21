import FlowBarCore
import SwiftUI

/// One palette result, drawn identically wherever it appears.
///
/// There are two shells over this list — the centered panel on ⌥Space and the
/// menubar popover's search section — and the cheapest way for two shells to
/// drift is for each to draw its own row. They don't: this is the only place a
/// `PaletteItem` becomes pixels.
struct PaletteRow: View {
    /// Whether the selection is the flat accent fill, which needs white text to
    /// stay legible. Under glass the selection is translucent and the row's
    /// normal colours read fine — forcing white there flattens it.
    private var onFlatSelection: Bool { selected && !Theme.isGlass }

    let item: PaletteItem
    /// Character offsets into `item.title` that matched the query.
    var highlight: [Int] = []
    /// Whether the keyboard cursor is on this row.
    var selected: Bool = false
    /// Whether this row is in a multi-open batch.
    var checked: Bool = false
    /// The panel gives rows more room than the 520pt popover does.
    var spacious: Bool = false

    var body: some View {
        HStack(spacing: spacious ? 10 : 8) {
            // A pinned row leads with its number, because that number is the
            // thing you are meant to learn — the icon says what kind of row it
            // is, which you can already tell from the title.
            if checked {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: spacious ? 14 : 12))
                    .foregroundStyle(onFlatSelection ? Color.white : Theme.accent)
                    .frame(width: spacious ? 20 : 16)
            } else if let n = item.jumpNumber {
                Text("\(n)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(onFlatSelection ? Color.white : Theme.accent)
                    .frame(width: spacious ? 20 : 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(onFlatSelection ? Color.white.opacity(0.22) : Theme.accent.opacity(0.18)))
            } else {
                Image(systemName: icon)
                    .font(.system(size: spacious ? 15 : 13))
                    .foregroundStyle(onFlatSelection ? Color.white : .secondary)
                    .frame(width: spacious ? 20 : 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: spacious ? 15 : 14))
                    .lineLimit(1).truncationMode(.middle)
                // A command's own description. Tasks have none: their name is
                // in the brief, one `→` away, and on the row it only crowded
                // out the project and tags you actually scan by.
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: spacious ? 13 : 12))
                        .foregroundStyle(onFlatSelection ? Color.white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                }
                if item.project != nil || !item.tags.isEmpty {
                    // Wraps rather than truncating: "#aws #fram…" tells you
                    // nothing, and a tag you cannot read is a tag that is not
                    // there.
                    WrapLayout(spacing: 6, lineSpacing: 3) {
                        if let project = item.project {
                            // A folder glyph so the project reads as a project
                            // rather than a hash-less tag beside the #tags.
                            HStack(spacing: 3) {
                                Image(systemName: "folder").font(.system(size: 10))
                                Text(project).font(.system(size: spacious ? 12 : 11))
                            }
                            .lineLimit(1)
                            .foregroundStyle(onFlatSelection ? Color.white.opacity(0.7) : .secondary)
                        }
                        ForEach(item.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: spacious ? 12 : 11))
                                .lineLimit(1)
                                .foregroundStyle(onFlatSelection ? Color.white.opacity(0.6)
                                                          : Color.secondary.opacity(0.7))
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            badges
        }
        .contentShape(Rectangle())
        .padding(.vertical, spacious ? 6 : 4)
        .padding(.horizontal, spacious ? 10 : 8)
        // Glass on macOS 26, the flat accent fill below it — the same pair the
        // rail already uses. On glass the selection is a *material*, so it reads
        // as lifted rather than painted, and the row's own colours survive
        // underneath instead of being flattened to white on blue.
        .glassSelection(isSelected: selected)
        // A hairline edge is what makes a translucent selection read as a
        // raised surface rather than a lighter patch of background.
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(Theme.isGlass ? 0.14 : 0), lineWidth: 1)
            }
        }
        .padding(.horizontal, spacious ? 8 : 0)
    }

    private var title: AttributedString {
        paletteHighlighted(item.title, offsets: highlight, selected: onFlatSelection)
    }

    /// The same marks the popover's `TaskRow` uses, in the same colours.
    private var badges: some View {
        HStack(spacing: 5) {
            ForEach(item.badges, id: \.self) { badge in
                switch badge {
                case .live:
                    Circle().fill(.green).frame(width: 6, height: 6)
                case .blocked:
                    glyph("hand.raised.fill", .orange)
                case .due(let label, let overdue):
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Color.white : (overdue ? .red : .orange))
                        .lineLimit(1)
                case .waiting:
                    glyph("hourglass", .orange)
                case .stale:
                    glyph("exclamationmark.triangle.fill", .yellow)
                case .done:
                    glyph("checkmark.circle.fill", .green)
                case .archived:
                    glyph("archivebox.fill", .orange)
                }
            }
        }
    }

    private func glyph(_ symbol: String, _ colour: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(onFlatSelection ? Color.white : colour)
    }

    /// A command that jumps to a section borrows that section's rail icon, so
    /// the row and the rail agree about what you are about to open.
    private var icon: String {
        switch item.action {
        case .section(let raw): return Section(rawValue: raw)?.icon ?? "command"
        case .newTask: return "plus"
        case .newReminder: return "bell.badge"
        case .refresh: return "arrow.clockwise"
        case .settings: return "gearshape"
        default: break
        }
        switch item.kind {
        case .task: return "circle.dashed"
        case .project: return "folder"
        case .playbook: return "play.rectangle"
        case .owner: return "gearshape.2"
        case .tag: return "number"
        case .reminder: return "bell"
        case .command: return "command"
        }
    }
}

/// The header above a result group.
struct PaletteSectionHeader: View {
    let title: String
    let count: Int
    var spacious: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, spacious ? 18 : 10)
        .padding(.top, 8).padding(.bottom, 2)
    }
}

/// What a row's tooltip says — shared for the same reason the row is.
func paletteHelp(_ item: PaletteItem) -> String {
    switch item.action {
    case .openTask(let slug), .openTaskSkippingPrompts(let slug):
        // The badges' meaning is folded in here, the way TaskRow does it: a
        // glyph you cannot hover is a glyph you have to guess at.
        var parts = [item.badges.contains(.blocked)
                     ? "\(slug) — stopped, waiting on you. Opens its terminal tab."
                     : "Open \(slug) (⌥ to skip permission prompts)"]
        for badge in item.badges {
            switch badge {
            case .live: parts.append("session running")
            case .due(let label, _): parts.append(label)
            case .waiting(let on): parts.append(on.map { "waiting on \($0)" } ?? "waiting")
            case .stale(let days): parts.append(days.map { "stale \($0)d" } ?? "stale")
            case .done: parts.append("done")
            case .archived: parts.append("archived")
            case .blocked: break
            }
        }
        if let n = item.jumpNumber { parts.append("⌘\(n)") }
        // Say why the skip-prompts option is absent, rather than leaving its
        // absence to be discovered.
        if item.hasLiveSession {
            parts.append("its session is already running, so its permission mode is fixed")
        }
        return parts.joined(separator: " · ")
    case .openProject(let s): return "Tasks in \(s)"
    case .openPlaybook(let s): return "Runs of \(s)"
    case .openOwner(let s): return "What \(s) owns"
    case .openTag(let t): return "Tasks tagged #\(t)"
    default: return item.subtitle ?? item.title
    }
}

/// Text with the matched characters picked out.
///
/// Colour rather than weight: a bold run inside a regular run reflows the
/// glyphs either side of it, so the line visibly shifts as you type. The accent
/// colour marks the same characters and moves nothing. On a selected row the
/// accent would vanish into the selection fill, so it is left plain.
func paletteHighlighted(_ text: String, offsets: [Int], selected: Bool) -> AttributedString {
    guard !offsets.isEmpty, !selected else { return AttributedString(text) }
    let marked = Set(offsets)
    var out = AttributedString()
    for (i, ch) in text.enumerated() {
        var piece = AttributedString(String(ch))
        if marked.contains(i) { piece.foregroundColor = Theme.accent }
        out += piece
    }
    return out
}

/// A flow layout: lay children out left to right and wrap when the line is full.
///
/// SwiftUI has no such container, and the alternative — an `HStack` that
/// truncates — loses information silently: "#aws #fram…" reads as a tag that
/// does not exist. A row is allowed to get taller; it is not allowed to lie.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if x > 0, x + spacing + width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += (x > 0 ? spacing : 0) + width
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            // Clamped, so one very long name truncates instead of running off
            // the end of the row.
            let width = min(size.width, bounds.width)
            if x > 0, x + spacing + width > bounds.width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            if x > 0 { x += spacing }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(width: width, height: size.height))
            x += width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
