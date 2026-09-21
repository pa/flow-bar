import AppKit
import FlowBarCore
import SwiftUI

/// The jump list, as a panel that appears **while ⌘ is held**.
///
/// **Why a second window rather than a strip in the palette.** It was a strip,
/// and the strip was unreadable: nine chips across 700pt left about forty points
/// of text each, which rendered three different `frammer-*` tasks as three
/// identical `fram…`. The problem is not the truncation, it is that the list was
/// paying rent in a panel with other work to do. A surface that costs nothing
/// when idle can give every pin a full row and its whole slug.
///
/// Holding ⌘ is also exactly when the list is useful: `⌘1`–`⌘9` fire from
/// anywhere, so the moment the modifier goes down is the moment you want to be
/// told what the numbers mean. Release and it is gone — no space, no chrome, and
/// nothing to dismiss.
struct JumpPanelView: View {
    let pinned: [PaletteItem]

    var body: some View {
        GlassGroup(spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("JUMP TO")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                // The keystroke belongs in the title, said once, rather than
                // repeated down a column nine times.
                Text(verbatim: "⌘ + number")
                    .font(.system(size: 11)).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 5)

            ForEach(Array(pinned.enumerated()), id: \.element.id) { i, item in
                row(number: i + 1, item: item)
            }
        }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaletteSurface())
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    /// One line: the number, the slug, and the two facts you scan by.
    ///
    /// **Deliberately not `PaletteRow`.** The palette's row carries an icon and
    /// the status badges, which makes it two lines tall — nine of those is a
    /// 450pt panel for a list whose entire job is to answer "which number". The
    /// state marks are already on the row in the palette above; repeating them
    /// here buys nothing and costs the compactness that lets all nine fit.
    private func row(number: Int, item: PaletteItem) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 16)
                .glassPill(fallback: Theme.accent.opacity(0.18), tinted: true)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).layoutPriority(2)
            if let project = item.project {
                HStack(spacing: 3) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text(project).font(.system(size: 12)).lineLimit(1)
                }
                .foregroundStyle(.secondary).layoutPriority(1)
            }
            ForEach(item.tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
    }
}

/// Owns the jump panel: a child window of the palette, shown while ⌘ is down.
@MainActor
final class JumpPanelController {
    private let store: Store
    private var panel: NSPanel?
    private var monitor: Any?
    /// The pending reveal, cancelled if the modifier turns out to be a chord.
    private var pending: Task<Void, Never>?

    /// How long ⌘ must be down, alone, before this is a *hold* rather than the
    /// first half of a chord.
    ///
    /// **Short on purpose.** A jump list is a quick hop, so a third of a second
    /// of nothing reads as the feature being broken. `⌘K`, `⌘C` and `⌘1` land
    /// their second key in roughly 50–80ms, so this clears a chord without
    /// making a hold feel deliberate. Zero would work too — any keypress
    /// cancels the reveal — but the panel would flash on the way through every
    /// shortcut in the app, which is the thing being avoided.
    private static let holdDelay = Duration.milliseconds(120)

    /// One compact line per pin, plus the header and padding. Nine rows has to
    /// stay a panel you can take in at a glance.
    private static let rowHeight: CGFloat = 24
    private static let chrome: CGFloat = 38

    init(store: Store) { self.store = store }

    /// Watch the modifier while `parent` is on screen.
    ///
    /// A **local** monitor: it only sees events delivered to this app, so it
    /// cannot observe what you type anywhere else. It is installed when the
    /// palette opens and removed when it closes.
    func attach(to parent: NSPanel) {
        detach()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            // Any key while the modifier is down means this was a chord, not a
            // hold — `⌘K` should open the actions panel, not flash this one.
            if event.type == .keyDown {
                self.cancelPending()
                self.hide()
                return event
            }
            if event.modifierFlags.contains(.command) {
                self.schedule(under: parent)
            } else {
                self.cancelPending()
                self.hide()
            }
            return event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cancelPending()
        hide()
    }

    /// Reveal, but only if ⌘ is still down when the delay elapses.
    private func schedule(under parent: NSPanel) {
        guard pending == nil, !store.palette.pinned.isEmpty,
              !store.paletteReadingDocument else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self else { return }
            // Re-read rather than trust the event: the key may have gone up
            // while we waited, and a panel that appears after you let go is
            // worse than one that never appears.
            guard NSEvent.modifierFlags.contains(.command) else { return }
            self.pending = nil
            self.show(under: parent)
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    // MARK: Showing

    private func show(under parent: NSPanel) {
        let pinned = store.palette.pinned
        // Nothing pinned, nothing to say. Holding ⌘ for a copy or a ⌘K should
        // not summon an empty box.
        guard !pinned.isEmpty else { return hide() }
        // **Not over a document.** A brief or the release notes is something you
        // are reading, and nine other tasks sliding in underneath is out of
        // place — ⌘ is busy there too (⌘C to copy, ⌘K for actions). List routes
        // keep it: those are still "pick a row". `⌘1`–`⌘9` keep working
        // everywhere regardless; this hides the reminder, not the feature.
        guard !store.paletteReadingDocument else { return hide() }

        let height = Self.chrome + CGFloat(pinned.count) * Self.rowHeight
        let width = parent.frame.width
        let panel = self.panel ?? build()
        self.panel = panel

        // **Content first, then the frame.** Assigning a hosting controller
        // resizes the window to that view's fitting size, so sizing beforehand
        // is thrown away — which is how this shipped as a 175pt stub with its
        // labels squeezed out entirely.
        panel.contentViewController = NSHostingController(
            rootView: JumpPanelView(pinned: pinned))
        // Same width as the palette and directly below it, with a small gap: a
        // separate surface reads as separate only if it looks detached.
        panel.setFrame(NSRect(x: parent.frame.minX,
                              y: parent.frame.minY - height - 8,
                              width: width, height: height),
                       display: true)
        // A child window so it follows the palette and dies with it; ordered
        // above so the palette's shadow doesn't fall across it.
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func build() -> NSPanel {
        // Only the initial size — `show` matches it to the palette's own frame
        // every time. Named rather than repeated so the two cannot disagree.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                                width: PaletteWindowController.width,
                                                height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true   // a legend, not a control
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}
