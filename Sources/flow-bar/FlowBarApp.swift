import AppKit
import SwiftUI

@main
struct FlowBarApp: App {
    @StateObject private var store = Store()

    init() {
        // Behave as a menubar agent even when launched as a bare binary
        // (the .app bundle also sets LSUIElement=1). Hides the dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menubar label. Extracted into its own View holding the Store as an
/// @ObservedObject so it reliably re-renders on @Published changes (an inline
/// label closure in the Scene does not observe reliably while the popover is
/// closed).
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
            // While busy, dim the brand mark (a reliably-rendered change) and
            // add a spinner; otherwise full-strength, with a brief check /
            // warning flashed after a switch/run completes.
            Image(nsImage: BrandIcon.menubar(monochrome: store.monochromeIcon))
                .opacity(store.isBusy ? 0.35 : 1)

            if store.isBusy {
                ProgressView().controlSize(.small)
            } else if store.recentResult == .success {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if store.recentResult == .failure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}
