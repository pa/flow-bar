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
            // Static flow brand "w" wave (colored, or monochrome template
            // per preference). Attention counts live on the Needs-you rail
            // badge inside the popover, not the menubar.
            Image(nsImage: BrandIcon.menubar(monochrome: store.monochromeIcon))
        }
        .menuBarExtraStyle(.window)
    }
}
