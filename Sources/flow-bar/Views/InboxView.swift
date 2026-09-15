import FlowBarCore
import SwiftUI

/// "Needs you": owner questions, overdue tasks, and tasks you're waiting on —
/// the cross-cutting attention list. Built from the dashboard metrics.
struct InboxView: View {
    @ObservedObject var store: Store
    /// Observed separately: the monitor is its own ObservableObject, so the
    /// Store's objectWillChange never fires when a session changes state.
    @ObservedObject private var sessions: SessionMonitor

    init(store: Store) {
        self.store = store
        self.sessions = store.sessionMonitor
    }

    /// Sessions blocked on a prompt right now. Empty unless session alerts are
    /// on, since nothing is being watched otherwise.
    private var blocked: [SessionMonitor.Row] {
        store.sessionAlertsEnabled ? sessions.attentionRows : []
    }

    var body: some View {
        Group {
            if store.metrics == nil, store.metricsLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let m = store.metrics {
                content(m)
            } else {
                Color.clear
            }
        }
        .onAppear { if store.metrics == nil { store.refreshMetrics() } }
    }

    private func content(_ m: DashboardMetrics) -> some View {
        let overdue = m.inProgress.filter { $0.isOverdue }.sortedByPriority()
        let waiting = m.inProgress.filter { $0.isWaiting && !$0.isOverdue }.sortedByPriority()
        let blocked = self.blocked
        let empty = m.questions.isEmpty && overdue.isEmpty && waiting.isEmpty && blocked.isEmpty

        return Group {
            if empty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(.green)
                    Text("Nothing needs you").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // First: the thing that is stopped dead right now. A
                        // session waiting on a prompt is costing you time as you
                        // read, which nothing else in this list is.
                        groupHeader("Sessions waiting on you", blocked.count,
                                    "hand.raised", .orange)
                        ForEach(blocked) { row in
                            BlockedSessionRow(row: row) {
                                // Clear before switching: they're on their way
                                // to deal with it, and the transcript won't say
                                // so until the turn ends.
                                sessions.dismissAlert(slug: row.slug)
                                store.switchTo(row.slug)
                            }
                        }
                        groupHeader("Questions for you", m.questions.count, "questionmark.bubble", .orange)
                        ForEach(m.questions.sortedByPriority()) { t in
                            TaskRow(task: t, action: { store.switchTo(t.slug) }, onPeek: { store.peekBrief(t.slug) }, onRemind: { store.beginReminder(for: t) })
                        }
                        groupHeader("Overdue", overdue.count, "calendar.badge.exclamationmark", .red)
                        ForEach(overdue) { t in
                            TaskRow(task: t, action: { store.switchTo(t.slug) }, onPeek: { store.peekBrief(t.slug) }, onRemind: { store.beginReminder(for: t) })
                        }
                        groupHeader("Waiting on", waiting.count, "hourglass", .secondary)
                        ForEach(waiting) { t in
                            TaskRow(task: t, action: { store.switchTo(t.slug) }, onPeek: { store.peekBrief(t.slug) }, onRemind: { store.beginReminder(for: t) })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// A live harness session stopped on a prompt.
    ///
    /// Not a `TaskRow`: that one is built around a `FlowTask`'s priority, due
    /// date and tags, none of which matter here. What matters is which harness
    /// is asking, what it is asking about, and how long it has been stuck —
    /// so the row says that and nothing else.
    private struct BlockedSessionRow: View {
        let row: SessionMonitor.Row
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let project = row.project, !project.isEmpty {
                                Text(project).foregroundStyle(.tertiary)
                                Text("·").foregroundStyle(.quaternary)
                            }
                            Text(row.harness.label).foregroundStyle(.tertiary)
                            Text("·").foregroundStyle(.quaternary)
                            // Claude Code's own wording when the hook gave us
                            // any — "Bash wants to run: npm test" says far more
                            // than "needs approval".
                            Text(row.statusText)
                                .foregroundStyle(Color.orange)
                                .lineLimit(1)
                            if let since = row.activity.since {
                                Text(RelativeAge.short(since))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .font(.system(size: 11))
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(isHovering ? 0.16 : 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .help("\(row.slug) — click to focus its \(row.harness.label) tab")
            .onHover { isHovering = $0 }
        }
    }

    @ViewBuilder
    private func groupHeader(_ title: String, _ count: Int, _ icon: String, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
                Text(title.uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
                Text("\(count)").font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
        }
    }
}
