import AppKit
import Combine
import SwiftUI

@main
struct FlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No real window — the menubar status item (managed in AppDelegate)
        // is the whole UI. Settings scene keeps SwiftUI happy.
        Settings { EmptyView() }
    }
}

/// Drives the status-bar item directly via AppKit. Unlike `MenuBarExtra`'s
/// SwiftUI label (which won't re-render while the popover is closed), we set
/// the button's image/indicator imperatively whenever the Store changes — so
/// background activity (spinner-dim) and completion (✓/⚠) always show.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellable: AnyCancellable?

    /// Real animated spinner shown in place of the icon while a terminal-
    /// spawning command runs.
    private lazy var spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isIndeterminate = true
        s.isDisplayedWhenStopped = false
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    /// Global mouse monitor that closes the popover on an outside click — a
    /// belt-and-braces for when .transient dismissal breaks after a nested
    /// SwiftUI Menu (the footer flow-root / Terminal menus) runs its own loop.
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        // Force dark appearance so the arrow/beak chrome renders dark to match
        // the opaque content (instead of picking up the desktop behind it).
        popover.appearance = NSAppearance(named: .darkAqua)
        // No open/close animation — an interrupted animation (fast click) is
        // what leaves the translucent ghost window. Instant show/hide avoids it.
        popover.animates = false
        popover.contentSize = NSSize(width: 440, height: 520)
        // One hosting controller for the app's lifetime — recreating it per
        // open caused a translucent ghost on fast outside-clicks.
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(store: store))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Indicator (✓ / • / ⚠) sits before the "w" icon.
        statusItem.button?.imagePosition = .imageTrailing

        if let button = statusItem.button {
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: BrandIcon.menubarHeight),
                spinner.heightAnchor.constraint(equalToConstant: BrandIcon.menubarHeight),
            ])
        }

        // Let switchTo() etc. close the popover for an instant-feeling action.
        Store.dismissHandler = { [weak self] in self?.popover.performClose(nil) }

        // Re-render the icon on any Store change.
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Reset to the In-progress tab, then show + start refreshing.
            store.openNonce += 1
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            store.beginActiveRefresh()
            installOutsideClickMonitor()
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // Stop all refreshing + free caches whenever the popover closes (incl.
    // outside-click). Nothing runs while the popover is closed.
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        store.endActiveRefresh()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if store.isWorking {
            // Terminal-spawning command in flight: show only the live spinner.
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "")
            statusItem.length = 26
            spinner.startAnimation(nil)
        } else if store.recentResult != nil {
            // Completion flash: show ONLY the result mark; the "w" returns
            // once it clears (spinner -> mark -> icon, never side by side).
            spinner.stopAnimation(nil)
            button.image = nil
            statusItem.length = 26
            button.attributedTitle = indicator()
        } else {
            spinner.stopAnimation(nil)
            statusItem.length = NSStatusItem.variableLength
            button.attributedTitle = NSAttributedString(string: "")
            button.image = BrandIcon.menubar(monochrome: store.monochromeIcon)
        }
    }

    private func indicator() -> NSAttributedString {
        func tag(_ s: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: BrandIcon.menubarHeight, weight: .bold),
            ])
        }
        switch store.recentResult {
        case .success:     return tag("✓", .systemGreen)
        case .alreadyOpen: return tag("•", .systemBlue)   // already open elsewhere
        case .failure:     return tag("⚠", .systemRed)
        case nil:          return NSAttributedString(string: "")
        }
    }
}
