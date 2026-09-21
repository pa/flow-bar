import AppKit
import FlowBarCore
import SwiftUI

/// The centered palette's window.
///
/// A borderless `NSPanel` **that can become key** — the override is the whole
/// trick. Borderless windows refuse key status by default, which would leave
/// the search field unable to take a keystroke; without it this is a picture of
/// a palette rather than a palette.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the centered palette: builds it, places it, sizes it to its results,
/// and closes it.
///
/// **Why a panel and not the popover.** An `NSPopover` is anchored to the
/// status item, so it opens in the top-right corner of a display you may not be
/// looking at, and its width is whatever fits under a menubar icon. A summoned
/// search bar has to appear where the eye already is — the centre of the screen
/// with the pointer on it — and to be wide enough that a task's slug and name
/// both fit on one line. Those are window properties, not popover properties.
///
/// The popover is untouched and still opens on a menubar click: ⌥Space is for
/// acting, the icon is for browsing.
@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    /// 750pt, which is Raycast's.
    ///
    /// Not copied on taste — measured. Screenshotted side by side on the same
    /// display, both windows centre on the same x, so their pixel widths are
    /// directly comparable: 1497 against our 1399 at 2x, which is 749pt against
    /// 700pt. The extra 50 all goes to the row, where a slug, a project and
    /// two or three `#tags` compete for one line before anything truncates.
    static let width: CGFloat = 750

    private let store: Store
    private let focus = PaletteFocus()
    /// The jump list, shown while ⌘ is held. See `JumpPanelController`.
    private lazy var jumpPanel = JumpPanelController(store: store)
    private var panel: PalettePanel?

    /// Screen-space y of the panel's **top** edge, held across resizes.
    ///
    /// The list grows and shrinks as you type, and it must grow *downward*: if
    /// the window stayed centred, every keystroke would move the field under
    /// the cursor you are typing into.
    private var topEdge: CGFloat = 0

    /// Run a result that the panel can't handle alone (anything but opening a
    /// task, which needs no UI at all).
    var onAction: ((PaletteAction) -> Void)?
    /// Called after the panel goes away, so the app can stop refreshing.
    var onHidden: (() -> Void)?

    init(store: Store) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = self.panel ?? build()
        self.panel = panel
        // Tells the view to clear its query and retake focus — a fresh summon
        // is a fresh search.
        store.paletteNonce += 1
        store.beginActiveRefresh()
        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focus.take()
        jumpPanel.attach(to: panel)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        jumpPanel.detach()
        panel.orderOut(nil)
        onHidden?()
    }

    /// Clicking another app, or anything else that takes key status, dismisses
    /// the palette — the same contract as the popover's `.transient` behaviour.
    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Build

    private func build() -> PalettePanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // No open/close animation, for the same reason the popover has none: an
        // interrupted animation is what leaves a translucent ghost behind.
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Follow the user to whichever space they're on, and be allowed over a
        // full-screen app — a launcher you have to leave full-screen to reach
        // is not a launcher.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let view = PaletteView(
            store: store,
            focus: focus,
            onAction: { [weak self] in self?.run($0) },
            onClose: { [weak self] in self?.hide() },
            onHeight: { [weak self] in self?.setHeight($0) })
        let host = NSHostingView(rootView: view)
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    // MARK: Geometry

    /// Centre horizontally on the screen the pointer is on, and sit above the
    /// true vertical centre — where Spotlight and every launcher since has put
    /// itself, because the eye lands high and the list needs room below.
    private func place(_ panel: PalettePanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        topEdge = PaletteGeometry.topEdge(in: visible)
        panel.setFrame(PaletteGeometry.frame(in: visible, width: Self.width,
                                             height: panel.frame.height),
                       display: false)
    }

    /// Resize to fit the results, keeping the top edge — and the field — still.
    private func setHeight(_ requested: CGFloat) {
        guard let panel else { return }
        let height = PaletteGeometry.clampHeight(requested)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        panel.setFrame(PaletteGeometry.resized(panel.frame, toHeight: height,
                                               topEdge: topEdge),
                       display: true)
        // The shadow is derived from the content's alpha, so a resized rounded
        // panel keeps the old outline until this is called.
        panel.invalidateShadow()
    }

    // MARK: Actions

    /// Dismiss first, then act — the panel disappearing *is* the acknowledgement
    /// that the keystroke landed, and `flow do` can take a moment to focus a tab.
    private func run(_ action: PaletteAction) {
        hide()
        onAction?(action)
    }
}
