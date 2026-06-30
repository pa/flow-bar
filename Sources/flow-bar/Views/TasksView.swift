import FlowBarCore
import SwiftUI

enum TaskFilter: String, CaseIterable, Identifiable {
    case inProgress = "In progress", backlog = "Backlog", done = "Done", all = "All"
    var id: String { rawValue }
    /// flow --status value (nil = all).
    var status: String? {
        switch self {
        case .inProgress: return "in-progress"
        case .backlog: return "backlog"
        case .done: return "done"
        case .all: return nil
        }
    }
}

/// The task list, with a status filter and the global search query.
/// In-progress uses the live polled list; other filters load on demand.
/// The filter is owned by the root so dashboard tiles can set it.
struct TasksView: View {
    @ObservedObject var store: Store
    let query: String
    @Binding var filter: TaskFilter

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(TaskFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 6)
            .onChange(of: filter) { f in
                if f != .inProgress { store.loadBrowse(status: f.status) }
            }

            content
        }
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
        return filter == .inProgress ? base.sortedByPriority() : base.sortedByStatusThenPriority()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered) { task in
                    TaskRow(task: task) { store.switchTo(task.slug) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
