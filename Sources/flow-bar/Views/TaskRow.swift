import FlowBarCore
import SwiftUI

/// One row in the in-progress list: priority dot, slug + name, status badges.
///
/// **Tooltips only fire on views that are not inside a Button's label.** A
/// plain-styled `Button` is a single platform view, so a `.help()` on an
/// `Image` within its label has nothing to attach to and never appears — the
/// badges declared tooltips for months and never showed one. Anything that
/// needs a tooltip is therefore a sibling of `mainButton` (as the checkbox
/// already was); anything that must stay inside it — the live dot — gets its
/// explanation folded into the button's own `rowHelp` instead.
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
                .helpIfPresent(rowHelp)
            // Badges sit OUTSIDE mainButton, for the same reason the checkbox
            // does: a plain-styled Button is a single platform view, so a
            // `.help()` on something inside its label has nothing to attach a
            // tooltip to and silently never fires. As siblings they are real
            // views and their tooltips work. (Their meaning is also folded
            // into `rowHelp`, so hovering the row body explains them too.)
            badges
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
        .contextMenu { rowMenu }
    }

    /// The right-click menu.
    ///
    /// **This exists to make the permission choice visible.** ⌥-click already
    /// opened a task with `--dangerously-skip-permissions`, but a modifier you
    /// can only learn from a tooltip is not a choice — and because the flag is
    /// inert on a task whose tab is still open, the first attempt is likely to
    /// land on a live task and look broken. Here the option is named, and on a
    /// live task it is disabled with the reason, which teaches the rule instead
    /// of leaving it to be guessed.
    @ViewBuilder
    private var rowMenu: some View {
        Button("Open") { onOpen(skipPermissions: false) }
            .disabled(!canOpen)
        Button("Open, skipping permission prompts") { onOpen(skipPermissions: true) }
            .disabled(!canOpen || task.isLive)
        if canOpen, task.isLive {
            // A session's permission mode is fixed when its process starts, so
            // there is nothing to apply it to while the tab is open.
            Text("Already running — close its tab to choose a mode")
        }
        if let onPeek {
            Divider()
            Button("View brief") { onPeek() }
        }
        if let onRemind {
            Button("Remind me") { onRemind() }
        }
    }

    /// Open through the same path the row's click uses, but with the mode
    /// stated rather than read from the keyboard.
    private func onOpen(skipPermissions: Bool) {
        Store.shared.switchTo(task.slug, skipPermissions: skipPermissions)
    }

    private var mainButton: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Title is the name, not the slug. Monitor-created
                        // tasks carry a machine slug (`slack-<channel>-<ts>`)
                        // that reads as noise in a list; the name is the
                        // human-facing summary. Slug still identifies the task
                        // in the detail view, where it's needed for commands.
                        // Fall back to the slug when a task has no name.
                        Text(task.name.isEmpty ? task.slug : task.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if task.isLive {
                            // `live` comes from flow itself (`flow list tasks
                            // --format json`), which resolves it from the
                            // recorded session's pid — so the dot means "the
                            // task's harness session is actually running", not
                            // merely "in progress". Its explanation rides in
                            // `rowHelp`; a `.help()` here would never fire.
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
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
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    /// Status badges. Each carries its own tooltip; see `body` for why they
    /// live outside `mainButton`.
    private var badges: some View {
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
                    .contentShape(Rectangle())
                    .help(dueHelp)
            }
            if task.isWaiting {
                badge("hourglass", .orange, help: waitingHelp)
            }
            if task.isStale {
                badge("exclamationmark.triangle.fill", .yellow, help: staleHelp)
            }
        }
        .padding(.leading, 2)
    }

    private func badge(_ symbol: String, _ color: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .frame(width: 16, height: 20)      // a real hover target, not a glyph
            .contentShape(Rectangle())
            .help(help)
    }

    private var dueHelp: String {
        guard let due = task.due else { return "due soon" }
        return task.isOverdue ? "overdue — was due \(due)" : "due \(due)"
    }

    private var waitingHelp: String {
        guard let on = task.waitingOn, !on.isEmpty else { return "waiting" }
        return "waiting on \(on)"
    }

    private var staleHelp: String {
        guard let days = task.staleDays, days > 0 else { return "stale" }
        return "stale \(days)d — no update in \(days) day\(days == 1 ? "" : "s")"
    }

    /// The whole row's tooltip: why this row can't be opened, or what its
    /// badges and its live dot mean. The dot and the badges are drawn inside
    /// or beside a Button, so this is the one place the live-session state can
    /// be explained on hover.
    private var rowHelp: String {
        guard canOpen else {
            return "\(task.isArchived ? "Archived" : "Done") — open the brief to review"
        }
        var parts: [String] = []
        parts.append("right-click for open options")
        if task.isLive { parts.append("live session — its terminal tab is still open") }
        if task.isWaiting { parts.append(waitingHelp) }
        if task.isStale { parts.append(staleHelp) }
        if task.isDueSoon { parts.append(dueHelp) }
        return parts.joined(separator: " · ")
    }

    private var priorityColor: Color {
        switch task.priorityValue {
        case .high: return .red
        case .medium: return .blue
        case .low: return .gray
        }
    }
}

private extension View {
    /// `.help("")` still installs a tooltip owner with no text, which reads as
    /// a broken tooltip; only attach one when there is something to say.
    @ViewBuilder
    func helpIfPresent(_ text: String) -> some View {
        if text.isEmpty { self } else { help(text) }
    }
}
