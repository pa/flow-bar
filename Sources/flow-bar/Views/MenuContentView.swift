import FlowBarCore
import SwiftUI

/// The popover shown when the menubar icon is clicked:
/// header + search field + filtered in-progress list + error banner + footer.
struct MenuContentView: View {
    @ObservedObject var store: Store

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Divider()

            if let error = store.errorText {
                errorBanner(error)
                Divider()
            }

            if store.tasks.isEmpty {
                centeredMessage("No in-progress tasks")
            } else if filteredTasks.isEmpty {
                centeredMessage("No matches for “\(query)”")
            } else {
                taskList
            }

            Divider()
            footer
        }
        .frame(width: 380, height: 480)
        .onAppear {
            store.refresh()
            // Focus the search field when the popover opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
            Text("Flow")
                .font(.system(size: 13, weight: .bold))
            Text(countLabel)
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
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search tasks…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { switchToFirstMatch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredTasks) { task in
                    TaskRow(task: task) { store.switchTo(task.slug) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func centeredMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
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

    // MARK: Derived data

    private var countLabel: String {
        let total = store.tasks.count
        let shown = filteredTasks.count
        if query.isEmpty || shown == total { return "In progress · \(total)" }
        return "\(shown) of \(total)"
    }

    /// Filter by slug / name / project / tags, then sort high-priority first.
    private var filteredTasks: [FlowTask] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = store.tasks.filter { task in
            guard !q.isEmpty else { return true }
            if task.slug.lowercased().contains(q) { return true }
            if task.name.lowercased().contains(q) { return true }
            if let p = task.projectName, p.lowercased().contains(q) { return true }
            if task.tagList.contains(where: { $0.lowercased().contains(q) }) { return true }
            return false
        }
        return base.sorted { a, b in
            if a.priority != b.priority {
                return rank(a.priorityValue) < rank(b.priorityValue)
            }
            return a.slug < b.slug
        }
    }

    private func switchToFirstMatch() {
        guard let first = filteredTasks.first else { return }
        store.switchTo(first.slug)
    }

    private func rank(_ p: FlowTask.Priority) -> Int {
        switch p { case .high: return 0; case .medium: return 1; case .low: return 2 }
    }
}
