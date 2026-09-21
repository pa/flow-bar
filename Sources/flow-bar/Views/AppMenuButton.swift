import AppKit
import FlowBarCore
import SwiftUI

/// The brand mark at the bottom-left of the palette, and the menu behind it.
///
/// **It is also where you are.** At the root it is a circle; inside a route it
/// grows into a pill carrying that route's name — the task slug, the project,
/// the playbook. A launcher has no title bar and no breadcrumb, so without it
/// the only thing saying which task's brief you are reading is a chip at the
/// far top of the panel, two hundred points from the actions that act on it.
///
/// **Why a second menu exists at all.** `⌘K` acts on the row in front of you;
/// this acts on flow-bar. The two never overlap, so neither list has to explain
/// what kind of thing its entries are about — putting "Settings…" among nine
/// lines about one task is exactly the mixing that stops a list being scannable.
///
/// **Why a panel and not an `NSMenu`.** The palette is a borderless
/// `.nonactivatingPanel` that dismisses when it stops being key; a system menu
/// takes key away from it, so the menu would open onto a palette that was
/// already closing.
struct AppMenuButton: View {
    let isOpen: Bool
    /// Where you are, when that is somewhere. Nil at the root.
    var label: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(nsImage: BrandIcon.menubar(monochrome: false))
                    .resizable().scaledToFit()
                    .frame(width: 15, height: 15)
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        // A slug can be long and the footer is not the place it
                        // gets to win. It truncates rather than sizing to fit:
                        // `fixedSize` was here, which pins a Text to its ideal
                        // width and so ignores the cap entirely — one long slug
                        // would have pushed the pill across the whole footer.
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                        .padding(.trailing, 4)
                }
            }
            // Sizes to the slug rather than reserving room for the longest one.
            // `frame(maxWidth: 200)` on the label takes *all* of the width it is
            // offered, and the footer offers it the whole panel — so the pill
            // came out 200pt wide with a short slug adrift in it. Fixing the
            // outer size to its ideal resolves that cap to the text's own width,
            // and only bites at 200.
            .fixedSize()
            // Same height and the same material as the shortcut capsule
            // opposite it — they are two controls on one row, and a plain fill
            // beside a glass one reads as one of them having been forgotten.
            // **A circle, stated rather than arrived at.** As a `minWidth` it
            // was only round because the 15pt mark happens to be narrower than
            // the control — grow the glyph past 32pt and it would quietly become
            // a squircle beside a capsule. With no label the frame is square and
            // the radius is half of it, which is the definition of the shape.
            .frame(width: label == nil ? Theme.footerControl : nil,
                   height: Theme.footerControl)
            .padding(.horizontal, label == nil ? 0 : 9)
            .glassSurface(cornerRadius: Theme.footerControl / 2, fallback: Theme.chip)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isOpen ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: label)
        .help(label.map { "\($0) — flow-bar \(AppInfo.version)" }
              ?? "flow-bar \(AppInfo.version) — release notes, settings")
    }
}
