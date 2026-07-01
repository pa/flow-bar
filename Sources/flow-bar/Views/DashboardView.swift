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
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
                if let s = store.stats, !s.isEmpty {
                    groupLabel("Your AI memory")
                    memoryCard(s)
                }

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
                            .font(.system(size: 13))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.chip)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(12)
        }
    }

    /// flow's "your AI remembered, so you didn't" numbers, as a feature card.
    /// Read-only (nothing to navigate to) — a delight/reassurance surface.
    private func memoryCard(_ s: FlowStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Headline: context recalls.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(s.contextRecalls ?? 0)")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("context recalls")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                if let w = s.weeklyRecalls {
                    Text(w)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accent)
                        .help("Weekly recalls")
                }
            }
            Text("flow remembered, so you didn't re-explain it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)

            Divider().opacity(0.4)

            // Supporting stats.
            FlowWrap(memoryStats(s)) { stat in
                HStack(spacing: 4) {
                    Text(stat.value).font(.system(size: 14, weight: .semibold))
                    Text(stat.label).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The secondary memory figures, only those present, as label/value chips.
    private func memoryStats(_ s: FlowStats) -> [LabeledStat] {
        var out: [LabeledStat] = []
        if let t = s.tokensReEstablished, t > 0 { out.append(.init(value: "~\(Self.abbrev(t))", label: "tokens saved")) }
        if let r = s.instantResumes, r > 0 { out.append(.init(value: "\(r)", label: "instant resumes")) }
        if let d = s.tasksDone, d > 0 { out.append(.init(value: "\(d)", label: "done")) }
        if let k = s.kbFacts, k > 0 { out.append(.init(value: "\(k)", label: "KB facts")) }
        return out
    }

    /// Abbreviate large counts: 701842 -> "702k", 5011319778 -> "5.0B".
    static func abbrev(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1e9)
        case 1_000_000...:     return String(format: "%.1fM", d / 1e6)
        case 1_000...:         return String(format: "%.0fk", d / 1e3)
        default:               return "\(n)"
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func tile(_ value: String, _ label: String, _ color: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(value).font(.system(size: 27, weight: .semibold)).foregroundStyle(color)
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.tile)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// A label/value pair for the memory card's supporting stats.
struct LabeledStat: Identifiable {
    let value: String
    let label: String
    var id: String { label }
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
