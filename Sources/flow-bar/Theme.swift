import SwiftUI

/// Surface colours for the popover.
///
/// **This used to be a set of opaque constants**, chosen so the UI "renders
/// identically on every macOS/SDK". That was the right call while the app
/// shipped a CI-built binary — but it is also exactly why the app looked
/// foreign on macOS 26. Liquid Glass is a *material*; a hardcoded RGB fill can
/// never be one, no matter which SDK you link against.
///
/// Now that the Homebrew cask compiles against the user's own SDK
/// (see CLAUDE.md → Distribution), the surfaces become material-aware:
///
/// - **macOS 26+** — backgrounds go transparent and the real material shows
///   through (`VisualEffectBackground` behind the content, `.glassEffect` on
///   the inset controls).
/// - **macOS 15** — the original opaque values, unchanged.
///
/// The app still commits to a **dark** appearance on both; only the material
/// changes. Semantic text styles (`.secondary`, `.tertiary`) were always stable
/// and are still used directly.
enum Theme {
    /// Whether this OS can render Liquid Glass. The single switch the rest of
    /// the UI branches on.
    static var isGlass: Bool {
        // Both halves matter: `GLASS` says the SDK we compiled against has the
        // API, `#available` says the machine we are running on has it. Without
        // the first, a macOS 15 SDK build would take the transparent
        // glass-backed path with no glass behind it — a hole, not a material.
        #if GLASS
        if #available(macOS 26.0, *) { return true } else { return false }
        #else
        return false
        #endif
    }

    // MARK: Legacy opaque values (macOS 15 path, and the glass fallbacks)

    /// Popover body.
    static let legacyBg    = Color(.sRGB, red: 0.114, green: 0.118, blue: 0.133, opacity: 1)
    /// Search field / inset inputs.
    static let legacyField = Color(.sRGB, red: 0.063, green: 0.075, blue: 0.094, opacity: 1)
    /// Segmented-control track.
    static let legacyTrack = Color(.sRGB, red: 0.060, green: 0.070, blue: 0.086, opacity: 1)

    // MARK: Metrics

    /// Height of the palette footer's two controls: the brand mark on the left
    /// and the shortcut capsule on the right.
    ///
    /// **One constant because they are one row.** Each sized itself from its own
    /// content, so the mark came out a 28pt circle beside a 34pt capsule — two
    /// controls at two heights on the same baseline, which reads as a mistake
    /// rather than a hierarchy. Anything that changes the padding inside either
    /// one must not be able to move only one of them.
    static let footerControl: CGFloat = 32

    // MARK: Surfaces

    /// Popover body. Transparent under glass so `VisualEffectBackground` shows;
    /// opaque otherwise.
    static var bg: Color { isGlass ? .clear : legacyBg }

    /// Search field / inset inputs. Under glass these sit *on* the popover
    /// material, so they need a light scrim rather than a dark slab — a dark
    /// fill over vibrancy just reads as a hole.
    static var field: Color { isGlass ? Color(.sRGB, white: 1, opacity: 0.07) : legacyField }

    /// Segmented-control track.
    static var track: Color { isGlass ? Color(.sRGB, white: 1, opacity: 0.06) : legacyTrack }

    /// Subtle elevated surface (dashboard tiles). Already translucent.
    static let tile   = Color(.sRGB, white: 1, opacity: 0.04)
    /// Chip / pill surface.
    static let chip   = Color(.sRGB, white: 1, opacity: 0.05)
    /// Dark wash laid over the vibrancy so text contrast never depends on the
    /// user's wallpaper. Tuned to stay clearly translucent while keeping
    /// near-white body text legible over a bright backdrop.
    static let scrim = Color(.sRGB, red: 0.075, green: 0.080, blue: 0.095, opacity: 0.62)

    /// Selected/active accent (fixed blue, not the user's system accent).
    static let accent = Color.blue
}
