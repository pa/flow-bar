import FlowBarCore
import SwiftUI

/// One row in the in-progress list: priority dot, slug + name, status badges.
struct TaskRow: View {
    let task: FlowTask
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(task.slug)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if task.isLive {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.green)
                                .help("live session")
                        }
                    }
                    HStack(spacing: 6) {
                        if let project = task.projectName {
                            Text(project)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !task.tagList.isEmpty {
                            Text(task.tagList.map { "#\($0)" }.joined(separator: " "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    if task.isDueSoon, let label = task.dueLabel {
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(task.isOverdue ? .red : .orange)
                            .lineLimit(1)
                            .help(task.due.map { "due \($0)" } ?? "due soon")
                    }
                    if task.isWaiting {
                        badge("hourglass", .orange, help: task.waitingOn ?? "waiting")
                    }
                    if task.isStale {
                        badge("exclamationmark.triangle.fill", .yellow,
                              help: "stale \(task.staleDays ?? 0)d")
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ symbol: String, _ color: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .help(help)
    }

    private var priorityColor: Color {
        switch task.priorityValue {
        case .high: return .red
        case .medium: return .blue
        case .low: return .gray
        }
    }
}
