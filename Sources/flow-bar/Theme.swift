import SwiftUI

/// Explicit, opaque colors used for all backgrounds/controls so the UI renders
/// identically on every macOS/SDK. Dynamic system colors (windowBackgroundColor,
/// controlBackgroundColor) and native control styles drift across OS versions —
/// they interact with vibrancy and Apple's per-release restyling — so we never
/// use them for fills. (Semantic text styles like .secondary are stable and are
/// fine to keep.)
enum Theme {
    /// Popover body.
    static let bg     = Color(.sRGB, red: 0.114, green: 0.118, blue: 0.133, opacity: 1)
    /// Search field / inset inputs.
    static let field  = Color(.sRGB, red: 0.063, green: 0.075, blue: 0.094, opacity: 1)
    /// Segmented-control track.
    static let track  = Color(.sRGB, red: 0.060, green: 0.070, blue: 0.086, opacity: 1)
    /// Subtle elevated surface (dashboard tiles).
    static let tile   = Color(.sRGB, white: 1, opacity: 0.04)
    /// Chip / pill surface.
    static let chip   = Color(.sRGB, white: 1, opacity: 0.05)
    /// Selected/active accent (fixed blue, not the user's system accent).
    static let accent = Color.blue
}
