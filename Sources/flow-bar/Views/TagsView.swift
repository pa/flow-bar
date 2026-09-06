import FlowBarCore
import SwiftUI

/// Browse tags → drill into the tasks carrying a tag. Tag counts come from the
/// dashboard metrics (`flow list tags`); the drill-in uses `flow list tasks --tag`.
struct TagsView: View {
    @ObservedObject var store: Store
    let query: String
    @State private var selected: String?

    var body: some View {
        Group {
            if let t = selected { detail(t) } else { list }
        }
        .onAppear {
            if store.metrics == nil { store.refreshMetrics() }
            // Opened pre-drilled from a dashboard top-tag tap.
            if let t = store.pendingTagDrill {
                selected = t
                store.loadTagTasks(t)
                store.pendingTagDrill = nil
            }
        }
    }

    private var tags: [TagCount] {
        let all = store.metrics?.tags ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.tag.lowercased().contains(q) }
    }

    private var list: some View {
        Group {
            if store.metrics == nil, store.metricsLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tags.isEmpty {
                Text(query.isEmpty ? "No tags" : "No matches")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(tags) { t in
                            Button { selected = t.tag; store.loadTagTasks(t.tag) } label: { row(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ t: TagCount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "number").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(t.tag).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(t.count)").font(.system(size: 13)).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func row(_ t: FlowTask) -> some View {
        TaskRow(task: t, action: { store.switchTo(t.slug) },
                onPeek: { store.peekBrief(t.slug) },
                onRemind: { store.beginReminder(for: t) }, showStatus: true)
    }

    private func detail(_ tag: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { selected = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12))
                        Text("#\(tag)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(store.tagTasks.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if store.tagTasksLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.tagTasks.isEmpty {
                Text("No tasks").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let split = store.tagTasks.splitByActivity()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(split.active) { t in row(t) }
                        if !split.finished.isEmpty {
                            FinishedSeparator(count: split.finished.count)
                            ForEach(split.finished) { t in row(t).opacity(0.75) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
