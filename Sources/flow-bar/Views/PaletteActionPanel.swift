import FlowBarCore
import SwiftUI

/// The ⌘K actions panel.
///
/// **This is what lets the footer stop growing.** It used to name every key at
/// once, so it outgrew the window and had to either drop hints (making the
/// available keys depend on the window width) or wrap to a second row. Listing
/// the primary action plus "⌘K Actions" and putting the rest in here is the
/// same move Raycast makes, and it scales: a row can gain a tenth action
/// without the footer noticing.
struct PaletteActionPanel: View {
    let entries: [PaletteActions.Entry]
    /// The keyboard cursor, or nil for a panel that is only ever clicked —
    /// the app menu, whose every entry is also a `@` command away.
    var cursor: Int?
    /// What the list is about. The app menu names the build instead, which is
    /// the one place a version number is worth a line of its own.
    var title: String = "ACTIONS"
    let run: (PaletteActions.Entry) -> Void

    /// **The mouse gets the same feedback the keyboard does.** Without it these
    /// were two panels of inert-looking text: the app menu has no cursor at all,
    /// so nothing in it ever highlighted and it did not read as a list of things
    /// you could click. Hover is also what keeps the two panels one component —
    /// the alternative was a second, dimmer row style for the menu that has no
    /// keyboard.
    @State private var hovered: String?

    var body: some View {
        GlassGroup(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 4)
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                let lit = i == cursor ?? -1 || hovered == entry.id
                Button { run(entry) } label: {
                    HStack(spacing: 10) {
                        Text(entry.title)
                            .font(.system(size: 13))
                            .foregroundStyle(lit && !Theme.isGlass ? Color.white : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let shortcut = entry.shortcut {
                            Text(verbatim: shortcut)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(lit && !Theme.isGlass
                                                 ? Color.white.opacity(0.8) : .secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassSelection(isSelected: lit)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
            }
        }
        }
        .padding(.bottom, 8)
        .frame(width: 330)
        // A floating popup is exactly what glass is for — it should read as
        // hovering over the brief, not as a hole cut in it.
        .background(PaletteSurface())
        .glassSurface(cornerRadius: 20, fallback: Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
