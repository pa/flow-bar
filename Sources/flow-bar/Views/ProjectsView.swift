import FlowBarCore
import SwiftUI

/// Projects list → drill into a project to see all its tasks.
/// The global search filters the projects list, or the tasks when drilled in.
struct ProjectsView: View {
    @ObservedObject var store: Store
    let query: String

    @State private var selected: Project?

    var body: some View {
        Group {
            if let p = selected {
                detail(p)
            } else {
                projectList
            }
        }
        .onAppear { if store.metrics == nil { store.refreshMetrics() } }
    }

    // MARK: List

    private var projects: [Project] {
        let all = store.metrics?.projects ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? all : all.filter {
            $0.slug.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
        return filtered.sorted { $0.inProgress != $1.inProgress
            ? $0.inProgress > $1.inProgress : $0.slug < $1.slug }
    }

    private var projectList: some View {
        Group {
            if store.metrics == nil, store.metricsLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projects.isEmpty {
                Text(query.isEmpty ? "No projects" : "No matches")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(projects) { p in
                            Button {
                                selected = p
                                store.loadProjectTasks(p.slug)
                            } label: { projectRow(p) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func projectRow(_ p: Project) -> some View {
        HStack(spacing: 8) {
            Circle().fill(priorityColor(p.priority)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(p.slug).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            countChip("\(p.inProgress)", .blue, "in progress")
            countChip("\(p.backlog)", .gray, "backlog")
            countChip("\(p.done)", .green, "done")
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func countChip(_ n: String, _ color: Color, _ help: String) -> some View {
        Text(n).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            .frame(minWidth: 18)
            .help(help)
    }

    // MARK: Detail (tasks under a project)

    private func detail(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selected = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13))
                    Text(p.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("· \(p.total)").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if store.projectTasksLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let tasks = store.projectTasks.filtered(by: query).sortedByStatusThenPriority()
                if tasks.isEmpty {
                    Text(query.isEmpty ? "No tasks" : "No matches")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(tasks) { t in
                                TaskRow(task: t, action: { store.switchTo(t.slug) }, onPeek: { store.peekBrief(t.slug) }, showStatus: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func priorityColor(_ p: String) -> Color {
        switch p { case "high": return .red; case "low": return .gray; default: return .blue }
    }
}
