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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(store: store))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading

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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = BrandIcon.menubar(monochrome: store.monochromeIcon)
        // Dim the whole item while a background flow command runs — a reliably
        // visible "working" state — and show a ✓/⚠ indicator on completion.
        button.alphaValue = store.isBusy ? 0.4 : 1.0
        button.attributedTitle = indicator()
    }

    private func indicator() -> NSAttributedString {
        func tag(_ s: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: " \(s)", attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            ])
        }
        if store.isBusy { return tag("⟳", .secondaryLabelColor) }
        switch store.recentResult {
        case .success: return tag("✓", .systemGreen)
        case .failure: return tag("⚠", .systemRed)
        case nil:      return NSAttributedString(string: "")
        }
    }
}
