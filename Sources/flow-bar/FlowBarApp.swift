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
            // flow brand "w" wave (colored, or monochrome template per
            // preference). Alongside it: a spinner while a background flow
            // command runs, then a brief check / warning when it finishes so
            // completion isn't ambiguous after the popover closes.
            Image(nsImage: BrandIcon.menubar(monochrome: store.monochromeIcon))
            if store.isBusy {
                ProgressView().controlSize(.small)
            } else if let result = store.recentResult {
                switch result {
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
