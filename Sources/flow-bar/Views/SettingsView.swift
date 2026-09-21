import FlowBarCore
import SwiftUI

/// Settings window content: global shortcut, general prefs, and about/updates.
/// Shown in its own NSWindow (not the popover) so the shortcut recorder keeps
/// stable keyboard focus.
struct SettingsView: View {
    @ObservedObject var store: Store
    /// Observed separately from the Store: the debounce lives on the monitor,
    /// and a Store-only observation would leave the slider's own readout stale
    /// while you drag it.
    @ObservedObject private var monitor: SessionMonitor
    /// Why the last "Fix" did nothing. A repair that quietly fails is the same
    /// as a broken button, and this one used to fail quietly by design.
    @State private var repairError: String?

    init(store: Store) {
        self.store = store
        self.monitor = store.sessionMonitor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                section("Shortcut") {
                    HStack {
                        Text("Toggle flow-bar").font(.system(size: 13))
                        Spacer()
                        ShortcutRecorder(shortcut: $store.toggleShortcut).fixedSize()
                    }
                    hint("Click the shortcut, then press a new key combo (needs a modifier). Press it from anywhere to open or close the popover.")
                }

                section("General") {
                    Toggle("Launch at login", isOn: $store.launchAtLogin)
                        .font(.system(size: 13))
                    if let err = store.launchAtLoginError {
                        // Previously a refused registration silently reverted the
                        // switch, which reads as "the toggle is broken".
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(err).font(.system(size: 11))
                        }
                        .foregroundStyle(.orange)
                    } else if store.launchAtLogin {
                        hint("macOS lists flow-bar under System Settings › General › "
                             + "Login Items, and posts a “Background Items Added” "
                             + "notification the first time it's registered.")
                    }
                    Toggle("Monochrome menubar icon", isOn: $store.monochromeIcon)
                        .font(.system(size: 13))
                }

                section("Session alerts") {
                    Toggle("Tell me when a session needs input",
                           isOn: $store.sessionAlertsEnabled)
                        .font(.system(size: 13))
                    if store.sessionAlertsEnabled {
                        hint("The menubar icon turns orange when a Claude or Codex "
                             + "session behind one of your tasks is stopped waiting for "
                             + "you. Click it to go straight to Needs-you, and click the "
                             + "session to land in its terminal.")
                        Toggle("Pulse the icon", isOn: $store.sessionAlertPulse)
                            .font(.system(size: 13))
                        hint(store.sessionAlertPulse
                             ? "A slow fade, so the icon catches your eye in a row of "
                               + "small coloured glyphs. Turn it off to keep the orange "
                               + "tint without the movement."
                             : "The icon still turns orange — it just won't move.")
                        // The slider only exists to tune a *guess*. While the
                        // hook is in effect there is no guess — so showing a
                        // control that changes nothing would be worse than
                        // showing none at all.
                        if monitor.hookActive {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                                Text("Exact detection — Claude Code tells flow-bar "
                                     + "the moment a session asks for something, so "
                                     + "there is no guessing and nothing to tune.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text("“Waiting on you” after")
                                    .font(.system(size: 13))
                                Slider(value: $monitor.debounce,
                                       in: SessionMonitor.debounceRange, step: 1)
                                    .frame(width: 130)
                                Text("\(Int(monitor.debounce))s")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                            }
                            hint("Fallback only, used while the Claude Code hook isn't "
                                 + "active: how long a tool call may sit unanswered "
                                 + "before it's assumed to be a permission prompt. "
                                 + "Sessions already running when alerts were switched "
                                 + "on fall back to this until they restart.")
                        }
                    } else {
                        hint("Off by default: this is the only part of flow-bar that "
                             + "watches anything while the popover is closed.")
                    }
                }

                section("About") {
                    HStack {
                        Text("Version").font(.system(size: 13))
                        Spacer()
                        Text("v\(store.currentVersion)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    installRow
                    updateRow
                    protectionRow
                    HStack(spacing: 16) {
                        Link("GitHub", destination: URL(string: "https://github.com/pa/flow-bar")!)
                        Link("Website", destination: URL(string: "https://pa.github.io/flow-bar")!)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 540)
        // Lets the material run behind the title bar, so the window is one
        // surface rather than a glass panel with an opaque strip on top.
        .background(SettingsWindowGlass())
        // The toggle's value is captured once at Store init, so re-sync with the
        // real system state whenever Settings is shown — the user may have
        // changed it in System Settings, or macOS may have revoked it.
        .onAppear {
            store.refreshLaunchAtLogin()
            // The hook can be removed behind our back (another tool rewriting
            // settings.json), so re-check whenever Settings is shown rather
            // than trusting what we saw at launch.
            monitor.refreshHookState()
        }
        .background(PopoverSurface())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch store.updateStatus {
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .failed(let msg):
            Button("Update failed — retry") { store.installUpdate() }
                .font(.system(size: 12)).foregroundStyle(.red).help(msg)
        case .idle:
            if let up = store.availableUpdate, store.isManagedInstall {
                // Homebrew owns this install, so brew does the rebuild — but
                // it's still one button. Self-installing the released zip here
                // would kill the Automation grant and de-nativise the UI; see
                // BrewUpgrade for why.
                VStack(alignment: .leading, spacing: 4) {
                    Button("Update to v\(up.version)") { store.installUpdate() }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    Text("flow-bar quits, Homebrew rebuilds it for your macOS, and it "
                         + "reopens when it's done — about a minute.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    // Still offered verbatim: some people would rather watch it
                    // run in their own terminal than trust a silent rebuild.
                    HStack(spacing: 8) {
                        Text(Updater.upgradeCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Button("Copy") { store.copyToPasteboard(Updater.upgradeCommand) }
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                }
            } else if let up = store.availableUpdate {
                Button("Update to v\(up.version)") { store.installUpdate() }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            } else {
                Button("Check for updates") { store.checkForUpdate(force: true) }
                    .font(.system(size: 12)).buttonStyle(.link)
            }
        }
    }

    /// How this build got here and what SDK it was compiled against. The SDK is
    /// what decides the UI's appearance, so a stale one is worth surfacing.
    @ViewBuilder
    private var installRow: some View {
        if let sdk = AppInfo.buildSDK {
            HStack(alignment: .top) {
                Text("Built for").font(.system(size: 13))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("macOS \(sdk) SDK")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if store.needsSDKRebuild {
                        Button("Rebuild natively") { store.copyToPasteboard(Updater.rebuildCommand) }
                            .font(.system(size: 11)).buttonStyle(.link)
                            .help("Copy “\(Updater.rebuildCommand)”")
                    }
                }
            }
            if store.needsSDKRebuild {
                hint("You're on macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) "
                     + "but this build was compiled against the macOS \(sdk) SDK, so the UI renders in "
                     + "compatibility mode. Rebuilding links it against your current SDK.")
            }
        }
    }

    /// Whether the stable signing identity is in place. Without it, macOS drops
    /// the Automation grant on every upgrade and `flow do` starts failing
    /// silently — worth being able to see and fix.
    @ViewBuilder
    private var protectionRow: some View {
        HStack {
            Text("Permissions survive updates").font(.system(size: 13))
            Spacer()
            if SelfSign.isProtected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 11))
                    Text("Yes").font(.system(size: 13))
                }
                .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield").font(.system(size: 11))
                        Text("No").font(.system(size: 13))
                    }
                    .foregroundStyle(.orange)
                    // `force`: the cooldown behind `bootstrap` is a loop guard
                    // for automatic relaunches, and a click is not a loop.
                    Button("Fix") {
                        switch SelfSign.attempt(force: true) {
                        case .relaunching, .alreadySigned: repairError = nil
                        case .failed(let why): repairError = why
                        }
                    }
                    .font(.system(size: 11)).buttonStyle(.link)
                }
            }
        }
        if let repairError {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(repairError).font(.system(size: 11))
            }
            .foregroundStyle(.orange)
        }
        if SelfSign.isProtected {
            hint("flow-bar has a stable signature, so macOS keeps your permission to "
                 + "control the terminal when it updates.")
        } else {
            hint("flow-bar's signature changes on every build, so macOS will ask you to "
                 + "re-allow terminal control after each update — and until you do, "
                 + "opening a task fails silently. “Fix” gives it a stable signature "
                 + "and relaunches.")
        }
    }

    /// A settings group: a label, then its controls on one glass card.
    ///
    /// **The card is what makes the grouping visible.** The settings were four
    /// runs of controls separated by whitespace on a flat fill, so which hint
    /// belonged to which toggle was decided by how close two things happened to
    /// sit — and the window was the last surface in the app still painting
    /// itself an opaque colour while every other one sampled what was behind it.
    /// One `GlassGroup` per card, because separate containers cannot sample each
    /// other's glass and siblings would refract inconsistently.
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                .tracking(0.6)
                .padding(.leading, 2)
            GlassGroup(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassSurface(cornerRadius: 14, fallback: Theme.tile)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// Makes the Settings window able to *show* glass.
///
/// **A material needs a transparent window to be a material.** SwiftUI's
/// `Settings` scene hands back an ordinary opaque `NSWindow`, and
/// `VisualEffectBackground` blends `.behindWindow` — so the blur had nothing to
/// sample and the panel rendered as the flat fill underneath it. Clearing the
/// window's own background is what lets the desktop through; making the title
/// bar transparent is what stops the result being a glass panel wearing an
/// opaque hat.
///
/// It reaches the window through a zero-size view rather than an `NSWindow`
/// subclass because the scene owns the window and never offers it to us —
/// `viewDidMoveToWindow` is the only moment it is in reach.
private struct SettingsWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
