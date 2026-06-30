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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 520)

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
                spinner.widthAnchor.constraint(equalToConstant: 14),
                spinner.heightAnchor.constraint(equalToConstant: 14),
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
            // Rebuild the content fresh each open so it always starts on the
            // In-progress tab (SwiftUI @State defaults), instead of persisting
            // the last-viewed section.
            popover.contentViewController = NSHostingController(
                rootView: MenuContentView(store: store))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
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
            NSAttributedString(string: " \(s)", attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
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
