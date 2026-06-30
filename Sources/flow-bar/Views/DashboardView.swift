import FlowBarCore
import SwiftUI

/// Overview/metrics home. All numbers are exact (computed from flow's JSON),
/// nothing estimated.
struct DashboardView: View {
    @ObservedObject var store: Store
    var onNavigate: (NavTarget) -> Void = { _ in }

    private let columns = [GridItem(.flexible()), GridItem(.flexible()),
                           GridItem(.flexible())]

    var body: some View {
        Group {
            if store.metrics == nil, store.metricsLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let m = store.metrics {
                content(m)
            } else if let err = store.metricsError {
                Text(err)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .onAppear { if store.metrics == nil { store.refreshMetrics() } }
    }

    private func content(_ m: DashboardMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                groupLabel("Work")
                LazyVGrid(columns: columns, spacing: 8) {
                    tile("\(m.inProgressCount)", "in progress", .blue) { onNavigate(.tasks(.inProgress)) }
                    tile("\(m.backlogCount)", "backlog", .gray) { onNavigate(.tasks(.backlog)) }
                    tile("\(m.doneCount)", "done", .green) { onNavigate(.tasks(.done)) }
                    tile("\(m.overdueCount)", "overdue", m.overdueCount > 0 ? .red : .secondary) { onNavigate(.section(.inbox)) }
                    tile("\(m.staleCount)", "stale", m.staleCount > 0 ? .yellow : .secondary) { onNavigate(.tasks(.inProgress)) }
                    tile("\(m.liveCount)", "live", m.liveCount > 0 ? .green : .secondary) { onNavigate(.tasks(.inProgress)) }
                }

                groupLabel("Needs you")
                LazyVGrid(columns: columns, spacing: 8) {
                    tile("\(m.questionCount)", "questions", m.questionCount > 0 ? .orange : .secondary) { onNavigate(.section(.inbox)) }
                    tile("\(m.overdueCount)", "overdue", m.overdueCount > 0 ? .red : .secondary) { onNavigate(.section(.inbox)) }
                    tile("\(m.waitingCount)", "waiting", .secondary) { onNavigate(.section(.inbox)) }
                }

                groupLabel("Automation")
                LazyVGrid(columns: columns, spacing: 8) {
                    tile("\(m.activeOwnerCount)", "owners", .purple) { onNavigate(.section(.owners)) }
                    tile("\(m.runsRunning)", "runs live", m.runsRunning > 0 ? .green : .secondary) { onNavigate(.section(.playbooks)) }
                    tile("\(m.activeProjectCount)", "projects", .blue) { onNavigate(.section(.projects)) }
                }

                if !m.topTags.isEmpty {
                    groupLabel("Top tags")
                    FlowWrap(m.topTags) { t in
                        Text("#\(t.tag) \(t.count)")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(12)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func tile(_ value: String, _ label: String, _ color: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(value).font(.system(size: 23, weight: .semibold)).foregroundStyle(color)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Minimal wrapping layout for tag chips (macOS 13 compatible).
struct FlowWrap<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items; self.content = content
    }
    var body: some View {
        // Simple two-per-row grid; good enough for up to 8 tags.
        let cols = [GridItem(.adaptive(minimum: 80), spacing: 6)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(items) { content($0) }
        }
    }
}
