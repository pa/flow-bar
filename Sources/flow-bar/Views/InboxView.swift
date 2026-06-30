import FlowBarCore
import SwiftUI

/// "Needs you": owner questions, overdue tasks, and tasks you're waiting on —
/// the cross-cutting attention list. Built from the dashboard metrics.
struct InboxView: View {
    @ObservedObject var store: Store

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
        let empty = m.questions.isEmpty && overdue.isEmpty && waiting.isEmpty

        return Group {
            if empty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.green)
                    Text("Nothing needs you").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        groupHeader("Questions for you", m.questions.count, "questionmark.bubble", .orange)
                        ForEach(m.questions.sortedByPriority()) { t in
                            TaskRow(task: t) { store.switchTo(t.slug) }
                        }
                        groupHeader("Overdue", overdue.count, "calendar.badge.exclamationmark", .red)
                        ForEach(overdue) { t in
                            TaskRow(task: t) { store.switchTo(t.slug) }
                        }
                        groupHeader("Waiting on", waiting.count, "hourglass", .secondary)
                        ForEach(waiting) { t in
                            TaskRow(task: t) { store.switchTo(t.slug) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ title: String, _ count: Int, _ icon: String, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
        }
    }
}
