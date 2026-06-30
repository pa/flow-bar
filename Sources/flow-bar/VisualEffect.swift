import AppKit
import SwiftUI

/// A SwiftUI background that uses the same `.popover` material AppKit draws the
/// popover (and its arrow/beak) with — so the content and the arrow match
/// instead of showing a seam where an opaque fill stops.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
