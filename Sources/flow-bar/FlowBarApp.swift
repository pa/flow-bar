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
            // Show an overdue count next to the icon when something needs
            // attention, so the menubar surfaces state without a click.
            let count = store.attentionCount
            Image(systemName: count > 0
                  ? "exclamationmark.triangle.fill"
                  : "point.3.connected.trianglepath.dotted")
            if count > 0 {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
