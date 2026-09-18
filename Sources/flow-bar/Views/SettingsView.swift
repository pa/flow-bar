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

                // Hidden until the experiment flag is set: the praxis backend
                // is not GA, and a picker with one option is not a choice.
                if store.praxisBackendAvailable { workSource }

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
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 460)
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
        .background(Theme.bg)
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
                    Button("Fix") { SelfSign.bootstrap() }
                        .font(.system(size: 11)).buttonStyle(.link)
                }
            }
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

    /// Which CLI drives the app. Behind the praxis experiment flag, so most
    /// installs never see it — see `praxisBackendFlagKey`.
    private var workSource: some View {
        section("Work source") {
            Picker("", selection: $store.backendKind) {
                ForEach(Backend.selectable) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            hint(store.backendKind == .flow
                 ? "Tasks, projects, playbooks and owners come from the “flow” CLI."
                 : "Tasks, projects, briefs, notes, tags and schedules come from "
                   + "the praxis harness (“prx work”). Playbooks and flow’s stats "
                   + "have no praxis equivalent, so those panes are hidden — opening "
                   + "a task goes to its existing session, or resumes it.")

            if store.backendKind == .praxis {
                pathRow("prx binary", placeholder: "find prx on PATH",
                        text: $store.praxisBinary)
                pathRow("Agent directory", placeholder: "~/.praxis/agent",
                        text: $store.praxisAgentDir)
            }

            HStack(spacing: 8) {
                Button(store.backendProbing ? "Checking…" : "Check") {
                    store.probeBackend()
                }
                .font(.system(size: 12)).buttonStyle(.link)
                .disabled(store.backendProbing)
                if let status = store.backendStatus {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: store.backendStatusOK
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(status).font(.system(size: 11)).lineLimit(3)
                    }
                    .foregroundStyle(store.backendStatusOK ? .green : .orange)
                    .textSelection(.enabled)
                }
            }

            hint("Experimental, off by default — enabled with “defaults write "
                 + "cloud.facets.flow-bar experimentalPraxisBackend -bool true”. Turn that "
                 + "off and the app returns to flow whatever is selected here.")
        }
    }

    /// A labelled path field. Empty is always meaningful here (“use the
    /// default”), so the placeholder states what empty does rather than being
    /// an example value.
    private func pathRow(_ label: String, placeholder: String,
                         text: Binding<String>) -> some View
    {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
