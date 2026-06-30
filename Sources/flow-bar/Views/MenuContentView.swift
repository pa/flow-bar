import FlowBarCore
import SwiftUI

/// App sections, shown as the left icon rail.
enum Section: String, CaseIterable, Identifiable {
    case dashboard, tasks, inbox, playbooks, projects, owners, team
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .tasks: return "In progress"
        case .inbox: return "Needs you"
        case .playbooks: return "Playbooks"
        case .projects: return "Projects"
        case .owners: return "Owners"
        case .team: return "Team"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "speedometer"
        case .tasks: return "list.bullet"
        case .inbox: return "tray.full"
        case .playbooks: return "play.rectangle"
        case .projects: return "folder"
        case .owners: return "gearshape.2"
        case .team: return "person.2"
        }
    }

    /// Sections whose content is a searchable list.
    var isSearchable: Bool {
        switch self {
        case .tasks, .projects, .playbooks, .owners: return true
        default: return false
        }
    }
}

/// Popover root: icon rail + content pane (header with global search, the
/// active section view, and a footer).
struct MenuContentView: View {
    @ObservedObject var store: Store

    @State private var section: Section = .tasks
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            pane
        }
        .frame(width: 440, height: 520)
        .onAppear {
            store.refresh()          // in-progress list (default view)
            store.refreshMetrics()   // powers the rail inbox badge
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Section.allCases) { s in
                Button {
                    section = s
                    onSectionChange(s)
                } label: {
                    Image(systemName: s.icon)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 30)
                        .background(section == s ? Color.accentColor.opacity(0.2) : .clear)
                        .foregroundStyle(section == s ? Color.accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .topTrailing) {
                            if let n = railBadge(s), n > 0 {
                                Text("\(n)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Circle().fill(.red).scaleEffect(1.3))
                                    .offset(x: -2, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(s.title)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 48)
    }

    // MARK: Pane

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if section.isSearchable {
                searchBar
            }
            Divider()
            sectionView
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch section {
        case .dashboard: DashboardView(store: store)
        case .tasks:     TasksView(store: store, query: query)
        case .team:      TeamView(store: store)
        case .inbox:     InboxView(store: store)
        case .playbooks, .projects, .owners:
            comingSoon(section.title)
        }
    }

    /// Red count badge on a rail icon (currently the Needs-you inbox).
    private func railBadge(_ s: Section) -> Int? {
        guard s == .inbox, let m = store.metrics else { return nil }
        return m.questionCount + m.overdueCount
    }

    private func comingSoon(_ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "hammer").font(.system(size: 20)).foregroundStyle(.tertiary)
            Text("\(title) — coming next").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header / search / footer

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section.icon).foregroundStyle(.tint)
            Text(section.title).font(.system(size: 13, weight: .bold))
            Text(countLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if isActiveLoading { ProgressView().controlSize(.small) }
            Button(action: refreshActive) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search \(section.title.lowercased())…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { if section == .tasks { switchToFirstTask() } }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Behavior

    private func onSectionChange(_ s: Section) {
        query = ""
        switch s {
        case .dashboard, .inbox, .playbooks, .projects, .owners: store.refreshMetrics()
        case .tasks:
            store.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        case .team: break
        }
    }

    private func refreshActive() {
        switch section {
        case .tasks: store.refresh()
        case .team: store.refreshTeam()
        default: store.refreshMetrics()
        }
    }

    private var isActiveLoading: Bool {
        switch section {
        case .tasks: return store.isLoading
        case .team: return store.teamLoading
        default: return store.metricsLoading
        }
    }

    private var countLabel: String {
        switch section {
        case .tasks:
            let total = store.tasks.count
            let shown = store.tasks.filtered(by: query).count
            return (query.isEmpty || shown == total) ? "\(total)" : "\(shown) of \(total)"
        case .team:
            let n = store.teamMembers.reduce(0) { $0 + $1.tasks.count }
            return store.teamMembers.isEmpty ? "" : "\(n)"
        case .inbox:
            guard let m = store.metrics else { return "" }
            let n = m.questionCount + m.overdueCount + m.waitingCount
            return n > 0 ? "\(n)" : ""
        default:
            return ""
        }
    }

    private func switchToFirstTask() {
        if let first = store.tasks.filtered(by: query).sortedByPriority().first {
            store.switchTo(first.slug)
        }
    }
}
