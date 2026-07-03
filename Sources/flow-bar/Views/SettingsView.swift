import FlowBarCore
import SwiftUI

/// Settings window content: global shortcut, general prefs, and about/updates.
/// Shown in its own NSWindow (not the popover) so the shortcut recorder keeps
/// stable keyboard focus.
struct SettingsView: View {
    @ObservedObject var store: Store

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
                    Toggle("Monochrome menubar icon", isOn: $store.monochromeIcon)
                        .font(.system(size: 13))
                }

                section("About") {
                    HStack {
                        Text("Version").font(.system(size: 13))
                        Spacer()
                        Text("v\(store.currentVersion)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    updateRow
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
            if let up = store.availableUpdate {
                Button("Update to v\(up.version)") { store.installUpdate() }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            } else {
                Button("Check for updates") { store.checkForUpdate(force: true) }
                    .font(.system(size: 12)).buttonStyle(.link)
            }
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
