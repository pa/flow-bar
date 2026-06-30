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
            segmentedTabs
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
                    if f != .inProgress { store.loadBrowse(status: f.status) }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
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
        .padding(.horizontal, 10).padding(.bottom, 6)
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
