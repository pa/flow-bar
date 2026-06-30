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
            // flow's brand "w" wave; an overdue count rides alongside when
            // something needs attention, so the menubar surfaces state.
            Image(nsImage: BrandIcon.menubar)
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
