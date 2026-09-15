import AppKit
import Combine
import FlowBarCore
import SwiftUI

@main
struct FlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menubar status item (managed in AppDelegate) is the main UI. The
        // Settings scene IS our real settings window — opened by ⌘, and by the
        // footer gear (via showSettingsWindow:), sharing the one Store.
        Settings { SettingsView(store: .shared) }
    }
}

/// Drives the status-bar item directly via AppKit. Unlike `MenuBarExtra`'s
/// SwiftUI label (which won't re-render while the popover is closed), we set
/// the button's image/indicator imperatively whenever the Store changes — so
/// background activity (spinner-dim) and completion (✓/⚠) always show.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellable: AnyCancellable?
    private var alertsCancellable: AnyCancellable?
    private var sessionCancellable: AnyCancellable?
    private var settingsWindow: NSWindow?

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

        // Show tooltips after ~350ms instead of AppKit's ~2s default.
        //
        // Every tooltip in this app explains a glyph the user is already
        // pointing at (a badge, a live dot, a disabled row), and all of the
        // text is computed from data we already hold — no work happens on
        // hover, so the stock delay is pure latency. `NSInitialToolTipDelay`
        // is undocumented but long-standing; `register` scopes it to this app
        // and lets a real user default still win.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])

        // Keep our code identity stable so the Automation (TCC) grant survives
        // upgrades. If the bundle needs signing this relaunches us, so stop here.
        if SelfSign.bootstrap() { return }

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
        // Footer "Settings…" opens the settings window.
        Store.openSettingsHandler = { [weak self] in self?.openSettings() }

        // Local reminder notifications: register the delegate + Snooze/Complete
        // actions, ask for permission, and re-sync the schedule with any saved
        // reminders. A tap opens the popover focused on that reminder.
        store.reminderScheduler.configure()
        store.reminderScheduler.requestAuthorizationIfNeeded()
        store.reconcileReminders()
        Store.openReminderHandler = { [weak self] id in
            self?.store.pendingReminderID = id
            self?.showPopoverForReminder()
        }

        // Global hotkey (default ⌥⌘F) toggles the popover from anywhere.
        HotKeyManager.shared.onFire = { [weak self] in self?.togglePopover() }
        HotKeyManager.shared.register(store.toggleShortcut)

        // Session alerts (opt-in): watch live harness sessions so the menubar
        // can badge when one is blocked on you. Driven off the same preference
        // the Settings toggle writes, so flipping it takes effect immediately
        // instead of at the next launch.
        alertsCancellable = store.$sessionAlertsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if enabled {
                        // The hook is what makes a permission prompt detectable
                        // at all — the JSONL shows nothing until it's answered.
                        SessionAlertHook.install()
                        self.store.sessionMonitor.start()
                    } else {
                        self.store.sessionMonitor.stop()
                        SessionAlertHook.remove()
                    }
                    self.updateIcon()
                }
            }

        // The monitor is a separate ObservableObject, so the Store's own
        // objectWillChange never fires for it — the icon needs its own hook.
        sessionCancellable = store.sessionMonitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }

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
            // A blocked session is the reason you clicked, so land on Needs-you
            // rather than the In-progress list. Read before `openNonce`, which
            // is what makes MenuContentView re-run `prepareForOpen`.
            store.pendingAttention = store.sessionAlertsEnabled
                && store.sessionMonitor.attentionCount > 0
            // Re-resolve now, so what opens is authoritative rather than
            // whatever the watch last saw.
            store.sessionMonitor.refreshNow()
            store.openNonce += 1
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            store.beginActiveRefresh()
            // They're looking at the list now, so an idle session has said what
            // it had to say. A hard block stays lit until it's actually dealt
            // with — see markTurnEndsSeen.
            store.sessionMonitor.markTurnEndsSeen()
            installOutsideClickMonitor()
        }
    }

    /// Show the popover (without toggling it closed) and bump `openNonce` so
    /// MenuContentView re-runs `prepareForOpen`, which honors `pendingReminderID`
    /// and lands on the Reminders section. Used by a notification tap.
    private func showPopoverForReminder() {
        guard let button = statusItem.button else { return }
        store.openNonce += 1
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        store.beginActiveRefresh()
    }

    /// Open (or focus) the Settings window. A real NSWindow we own — reliable
    /// from a menubar-agent context (sendAction to the SwiftUI Settings scene is
    /// flaky here). ⌘, still opens the SwiftUI Settings scene, which renders the
    /// same SettingsView bound to the same shared Store.
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let w = NSWindow(contentViewController: host)
            w.title = "flow-bar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            // The spinner owns the item now; a half-faded one looks broken.
            stopPulse()
        } else if store.recentResult != nil {
            // Completion flash: show ONLY the result mark; the "w" returns
            // once it clears (spinner -> mark -> icon, never side by side).
            spinner.stopAnimation(nil)
            button.image = nil
            statusItem.length = 26
            stopPulse()
            button.attributedTitle = indicator()
        } else {
            spinner.stopAnimation(nil)
            statusItem.length = NSStatusItem.variableLength
            button.attributedTitle = NSAttributedString(string: "")
            button.image = BrandIcon.menubar(monochrome: store.monochromeIcon,
                                             alerting: isAlerting)
            button.toolTip = isAlerting ? alertTooltip : nil
            // The tint is the signal; the pulse is only how loudly it's said.
            // Turning the pulse off must leave the icon orange.
            if isAlerting, store.sessionAlertPulse { startPulse() } else { stopPulse() }
        }
    }

    // MARK: Attention pulse

    /// Breathe the icon while a session is blocked.
    ///
    /// A static orange mark is easy to miss in a menu bar that is already a row
    /// of small coloured glyphs — the eye is drawn by *change*, not by hue. The
    /// pulse is slow and shallow on purpose: enough to catch a glance, not
    /// enough to nag while you work.
    ///
    /// This is the app's only repeating timer, and it exists solely while
    /// something is actually blocked — it starts when a session stops for you
    /// and dies the moment it doesn't, so an idle machine never runs it.
    private var pulseTimer: Timer?
    private var pulseDim = false

    private static let pulsePeriod: TimeInterval = 0.95
    private static let pulseFloor: CGFloat = 0.38

    private func startPulse() {
        guard pulseTimer == nil else { return }
        if SessionMonitor.verbose { FlowClient.log("icon: pulse started") }
        pulseDim = false
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pulsePeriod, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.stepPulse() }
        }
        // Keep breathing while a menu or a resize is tracking the run loop;
        // otherwise the icon freezes mid-fade exactly when the user looks up.
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
        stepPulse()   // start now rather than after the first interval
    }

    private func stepPulse() {
        guard let button = statusItem.button else { return }
        pulseDim.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.pulsePeriod * 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = pulseDim ? Self.pulseFloor : 1
        }
    }

    private func stopPulse() {
        guard pulseTimer != nil else { return }
        if SessionMonitor.verbose { FlowClient.log("icon: pulse stopped") }
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseDim = false
        // Snap back rather than animate: the next thing drawn may be the
        // spinner or a result mark, and neither should fade in from half alpha.
        statusItem.button?.animator().alphaValue = 1
        statusItem.button?.alphaValue = 1
    }

    /// Whether any live session is blocked waiting for the user.
    ///
    /// Ranks below the spinner and the result flash on purpose: those are
    /// transient and describe something the user just did, so they get the icon
    /// for their second or two and the alert returns underneath.
    private var isAlerting: Bool {
        store.sessionAlertsEnabled && store.sessionMonitor.attentionCount > 0
    }

    private var alertTooltip: String {
        let rows = store.sessionMonitor.attentionRows
        guard !rows.isEmpty else { return "" }
        // Name what's actually blocked; the icon alone can't say which task.
        let names = rows.prefix(3).map(\.slug).joined(separator: ", ")
        let more = rows.count > 3 ? " and \(rows.count - 3) more" : ""
        return rows.count == 1
            ? "\(names) is waiting on you"
            : "\(rows.count) sessions waiting on you: \(names)\(more)"
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
