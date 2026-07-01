import SwiftUI

/// Shared status coloring for tasks and playbook runs (backlog / in-progress /
/// done / archived), so every list reads the same.
enum StatusStyle {
    static func color(_ status: String) -> Color {
        switch status {
        case "in-progress": return .blue
        case "done":        return .green
        case "archived":    return .orange
        // Brighter blue-grey — plain .gray was nearly invisible on the dark fill.
        case "backlog":     return Color(.sRGB, red: 0.60, green: 0.65, blue: 0.73, opacity: 1)
        default:            return Color(.sRGB, white: 0.70, opacity: 1)
        }
    }

    static func label(_ status: String) -> String {
        status == "in-progress" ? "in progress" : status
    }
}

/// A small colored capsule showing a task/run status.
struct StatusPill: View {
    let status: String
    var body: some View {
        let c = StatusStyle.color(status)
        Text(StatusStyle.label(status))
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.24))
            .foregroundStyle(c)
            .clipShape(Capsule())
    }
}
