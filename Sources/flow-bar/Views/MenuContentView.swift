import FlowBarCore
import SwiftUI

/// The popover shown when the menubar icon is clicked.
/// Phase 2: header + scrollable in-progress list + error banner + footer.
/// (Search bar arrives in Phase 3.)
struct MenuContentView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = store.errorText {
                errorBanner(error)
                Divider()
            }

            if store.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { store.refresh() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("Flow")
                .font(.system(size: 13, weight: .bold))
            Text("In progress · \(store.tasks.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(sortedTasks) { task in
                    TaskRow(task: task) { store.switchTo(task.slug) }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 420)
    }

    private var emptyState: some View {
        Text("No in-progress tasks")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // High priority first, then by slug.
    private var sortedTasks: [FlowTask] {
        store.tasks.sorted { a, b in
            if a.priority != b.priority {
                return rank(a.priorityValue) < rank(b.priorityValue)
            }
            return a.slug < b.slug
        }
    }

    private func rank(_ p: FlowTask.Priority) -> Int {
        switch p { case .high: return 0; case .medium: return 1; case .low: return 2 }
    }
}
