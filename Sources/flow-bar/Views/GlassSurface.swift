import AppKit
import SwiftUI

// `#if GLASS` is set by `build-app.sh` when the macOS SDK it is compiling
// against is 26 or newer (see its `detect_sdk_version`). It is NOT a runtime
// check and cannot be replaced by one: `#available(macOS 26.0, *)` decides
// whether to *call* an API on the machine running the app, and says nothing
// about whether that API exists in the SDK being compiled against. `glassEffect`
// does not exist in the macOS 15 SDK, so on a Command-Line-Tools machine the
// file did not compile at all — and since the cask compiles on the user's
// machine, that meant a macOS 15 user could not install flow-bar. Caught by the
// `command-line-tools` CI job; invisible to every build made with Xcode.
//
// Both guards are needed together: the `#if` decides whether the code can be
// built, the `#available` decides whether it may run.

/// Real window-behind vibrancy for the popover.
///
/// The app used to paint every surface with an opaque fill so it "renders
/// identically on every macOS/SDK". That guarantee is what kept it looking
/// foreign on macOS 26: Liquid Glass is a *material*, and a hardcoded RGB fill
/// can never be one. This view puts an actual `NSVisualEffectView` behind the
/// content so the popover samples what's behind it.
///
/// `.behindWindow` (not `.withinWindow`) is the whole point — it blurs the
/// desktop/app underneath, which is what makes the popover read as part of the
/// system rather than a dark rectangle floating on top of it.
struct VisualEffectBackground: NSViewRepresentable {
    /// `.hudWindow`, not `.popover`.
    ///
    /// `.popover` samples the desktop and goes LIGHT over a light wallpaper.
    /// This app commits to a dark appearance, so its near-white text then sat on
    /// a pale surface and became unreadable. `.hudWindow` keeps a dark
    /// translucent panel whatever is behind it — still glass, still sampling,
    /// but the contrast floor no longer depends on the user's wallpaper.
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        // `.active` rather than `.followsWindowActiveState`: the popover is a
        // transient panel and its window is frequently "inactive" while still
        // on screen, which would otherwise flatten the material to grey.
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.state = .active
    }
}

extension View {
    /// Liquid Glass on macOS 26, a plain translucent fill below it.
    ///
    /// Used for the inset controls (search field, segmented track, tiles) that
    /// sit *on* the popover material. On 26 these become their own glass
    /// elements; on 15 they fall back to the subtle white overlays the app
    /// already used, so nothing regresses.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, fallback: Color) -> some View {
        #if GLASS
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(fallback)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(fallback)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }

    /// Interactive glass for controls that respond to clicks (rail items,
    /// segmented tabs). On 26 `.interactive` gets the press/hover response the
    /// system uses; below it this is an ordinary tinted fill.
    @ViewBuilder
    func glassControl(cornerRadius: CGFloat, tinted: Bool, fallback: Color) -> some View {
        #if GLASS
        if #available(macOS 26.0, *) {
            if tinted {
                self.glassEffect(.regular.tint(Theme.accent.opacity(0.55)).interactive(),
                                 in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.interactive(),
                                 in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background(fallback)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(fallback)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }
}

extension View {
    /// The selected-section pill in the icon rail. Under glass this is a real
    /// interactive glass capsule; below it, the tinted fill the rail always had.
    @ViewBuilder
    func railSelection(isSelected: Bool) -> some View {
        #if GLASS
        if #available(macOS 26.0, *) {
            if isSelected {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 7))
            } else {
                self.clipShape(RoundedRectangle(cornerRadius: 7))
            }
        } else {
            self.background(isSelected ? Color.accentColor.opacity(0.2) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        #else
        self.background(isSelected ? Color.accentColor.opacity(0.2) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        #endif
    }
}

extension View {
    /// The active tab in a segmented control. Accent-tinted glass on macOS 26 —
    /// the tint is what keeps it reading as "selected" once the flat blue fill
    /// is gone; below 26 it stays that flat blue fill.
    @ViewBuilder
    func segmentSelection(isSelected: Bool) -> some View {
        #if GLASS
        if #available(macOS 26.0, *) {
            if isSelected {
                self.glassEffect(.regular.tint(Theme.accent).interactive(),
                                 in: .rect(cornerRadius: 6))
            } else {
                self.clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            self.background(isSelected ? Theme.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        #else
        self.background(isSelected ? Theme.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        #endif
    }
}

/// The popover's backdrop: real vibrancy plus a dark scrim.
///
/// The scrim is what makes the glass safe. Vibrancy alone leaves contrast at the
/// mercy of whatever is behind the window — over a bright wallpaper the panel
/// lifts and light text washes out (exactly what happened with `.popover`). A
/// fixed dark wash under the content guarantees a contrast floor on ANY
/// backdrop while still letting the blur read through.
struct PopoverSurface: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            Theme.scrim
        }
        .ignoresSafeArea()
    }
}
