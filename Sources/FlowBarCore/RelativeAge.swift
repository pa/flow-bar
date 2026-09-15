import Foundation

/// Compact ages for session rows: `4s`, `2m`, `1h`.
///
/// Not `RelativeDateTimeFormatter` — its "4 seconds ago" is far too wide for a
/// badge in a menubar popover row, and it localises into widths that can't be budgeted.
public enum RelativeAge {
    public static func short(_ date: Date, now: Date = Date()) -> String {
        // Clamped at zero: transcript timestamps are UTC from another process,
        // so a slightly-ahead clock must read "0s", never "-3s".
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}
