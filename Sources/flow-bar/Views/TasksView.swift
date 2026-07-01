import FlowBarCore
import SwiftUI

enum TaskFilter: String, CaseIterable, Identifiable {
    case inProgress = "In progress", backlog = "Backlog", done = "Done"
    case all = "All", archived = "Archived"
    var id: String { rawValue }
    /// flow --status value (nil = all). Archived is orthogonal to status.
    var status: String? {
        switch self {
        case .inProgress: return "in-progress"
        case .backlog: return "backlog"
        case .done: return "done"
        case .all, .archived: return nil
        }
    }
}

enum TaskSort: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case recentlyUpdated = "Recently updated"
    var id: String { rawValue }
}

/// The task list, with a status filter and the global search query.
/// In-progress uses the live polled list; other filters load on demand.
/// The filter is owned by the root so dashboard tiles can set it.
struct TasksView: View {
    @ObservedObject var store: Store
    let query: String
    @Binding var filter: TaskFilter
    @State private var sort: TaskSort = .priority

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                segmentedTabs
                sortMenu
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            content
        }
    }

    /// Custom segmented control (explicit colors) so it looks identical on
    /// every macOS/SDK — the native Picker(.segmented) restyles per OS version.
    private var segmentedTabs: some View {
        HStack(spacing: 2) {
            ForEach(TaskFilter.allCases) { f in
                Button {
                    filter = f
                    switch f {
                    case .inProgress: break
                    case .archived:   store.loadArchived()
                    default:          store.loadBrowse(status: f.status)
                    }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 13, weight: filter == f ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(filter == f ? Color.white : Color(.sRGB, white: 0.62, opacity: 1))
                        .background(filter == f ? Theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Sort picker (Priority / Recently updated).
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(TaskSort.allCases) { s in Text(s.rawValue).tag(s) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14))
                .foregroundStyle(sort == .priority ? Color(.sRGB, white: 0.62, opacity: 1) : Color.white)
                .frame(width: 30, height: 27)
                .background(sort == .priority ? Theme.track : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(sort.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorText, source.isEmpty {
            errorBanner(error)
        } else if source.isEmpty {
            centered("No \(filter.rawValue.lowercased()) tasks")
        } else if filtered.isEmpty {
            centered("No matches for “\(query)”")
        } else {
            list
        }
    }

    /// The unfiltered source list for the current filter.
    private var source: [FlowTask] {
        filter == .inProgress ? store.tasks : store.browseTasks
    }

    private var isLoading: Bool {
        filter == .inProgress ? store.isLoading : store.browseLoading
    }

    private var filtered: [FlowTask] {
        let base = source.filtered(by: query)
        switch sort {
        case .recentlyUpdated:
            return base.sortedByRecentlyUpdated()
        case .priority:
            return filter == .inProgress ? base.sortedByPriority() : base.sortedByStatusThenPriority()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered) { task in
                    TaskRow(task: task, action: { store.switchTo(task.slug) },
                            onPeek: { store.peekBrief(task.slug) },
                            showStatus: filter == .all || filter == .archived)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
