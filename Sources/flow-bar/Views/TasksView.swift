import FlowBarCore
import SwiftUI

/// The in-progress task list, filtered by the global search query.
struct TasksView: View {
    @ObservedObject var store: Store
    let query: String

    var body: some View {
        Group {
            if let error = store.errorText, store.tasks.isEmpty {
                errorBanner(error)
            } else if store.tasks.isEmpty {
                centered("No in-progress tasks")
            } else if filtered.isEmpty {
                centered("No matches for “\(query)”")
            } else {
                list
            }
        }
    }

    private var filtered: [FlowTask] {
        store.tasks.filtered(by: query).sortedByPriority()
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
