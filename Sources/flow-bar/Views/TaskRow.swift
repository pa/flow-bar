import FlowBarCore
import SwiftUI

/// One row in the in-progress list: priority dot, slug + name, status badges.
struct TaskRow: View {
    let task: FlowTask
    let action: () -> Void
    /// Optional "view brief" affordance; when set, a doc button is shown.
    var onPeek: (() -> Void)? = nil
    /// Optional "remind me" affordance; when set, a bell button is shown.
    var onRemind: (() -> Void)? = nil
    /// Show a colored status pill (used where a list mixes statuses, e.g. the
    /// Projects drill-in). Off in the In-progress list, where it's redundant.
    var showStatus: Bool = false
    /// Show the project name. Off in the Projects drill-in (redundant there).
    var showProject: Bool = true

    // Multi-select. All defaulted, so the other six TaskRow call sites compile
    // untouched and — because the checkbox is inside `if showCheckbox` — keep
    // byte-identical geometry.
    var showCheckbox: Bool = false
    var isChecked: Bool = false
    var onToggle: (() -> Void)? = nil

    private var isDone: Bool { task.status == "done" }
    /// Done or archived tasks have nothing to switch to — `flow do` on them is a
    /// no-op at best, so the open action is disabled (brief peek stays available).
    private var canOpen: Bool { task.canOpen }

    var body: some View {
        HStack(spacing: 2) {
            if showCheckbox {
                // A sibling of mainButton, not inside it, so the two hit regions
                // never overlap: ticking must not also open the task. 26x26
                // matches the peek button's target size.
                Button { onToggle?() } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(isChecked ? Theme.accent : Color.secondary.opacity(0.55))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.25)
                .help(canOpen ? (isChecked ? "Uncheck" : "Check to open with others")
                              : "Nothing to open")
            }
            mainButton
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.7)
                .help(canOpen ? "" : "\(task.isArchived ? "Archived" : "Done") — open the brief to review")
            if let onPeek {
                Button(action: onPeek) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View brief")
            }
            if let onRemind {
                Button(action: onRemind) {
                    Image(systemName: "bell")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remind me about this task")
            }
        }
        .padding(.trailing, 4)
    }

    private var mainButton: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.slug)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if task.isLive {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                                .help("live session")
                        }
                    }
                    HStack(spacing: 6) {
                        if showStatus {
                            StatusPill(status: task.status)
                        }
                        if let project = task.projectName, showProject {
                            // Folder glyph so the project reads as a project, not
                            // a hash-less tag sitting next to the #tags.
                            HStack(spacing: 3) {
                                Image(systemName: "folder").font(.system(size: 10))
                                Text(project).font(.system(size: 13)).lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }
                        if !task.tagList.isEmpty {
                            Text(task.tagList.map { "#\($0)" }.joined(separator: " "))
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    if task.isArchived {
                        badge("archivebox.fill", .orange, help: "archived")
                    }
                    if isDone {
                        badge("checkmark.circle.fill", .green, help: "done")
                    }
                    if task.isDueSoon, let label = task.dueLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
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
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ symbol: String, _ color: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
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
