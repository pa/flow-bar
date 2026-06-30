import FlowBarCore
import SwiftUI

/// Playbooks list → drill into a playbook's recent runs. Read-mostly, with an
/// explicit Run action (spawns a tab).
struct PlaybooksView: View {
    @ObservedObject var store: Store
    let query: String

    @State private var selected: Playbook?

    var body: some View {
        Group {
            if let p = selected { detail(p) } else { list }
        }
        .onAppear { if store.playbooks.isEmpty { store.refreshPlaybooks() } }
    }

    private var playbooks: [Playbook] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.playbooks
        let filtered = q.isEmpty ? all : all.filter {
            $0.slug.lowercased().contains(q) || ($0.project?.lowercased().contains(q) ?? false)
        }
        return filtered.sorted { $0.slug < $1.slug }
    }

    private func runs(for slug: String) -> [PlaybookRun] {
        store.runs.filter { $0.playbook == slug }
    }

    private var list: some View {
        Group {
            if store.playbooks.isEmpty, store.playbooksLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playbooks.isEmpty {
                Text(query.isEmpty ? "No playbooks" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(playbooks) { p in
                            Button { selected = p } label: { row(p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ p: Playbook) -> some View {
        let rs = runs(for: p.slug)
        let live = rs.filter { $0.status == "in-progress" }.count
        return HStack(spacing: 8) {
            Image(systemName: "play.rectangle").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let proj = p.project {
                    Text(proj).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if live > 0 {
                Text("\(live) live").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
            }
            Text("\(rs.count) runs").font(.system(size: 11)).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func detail(_ p: Playbook) -> some View {
        let rs = runs(for: p.slug).sorted { $0.slug > $1.slug }  // newest-ish first by slug timestamp
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { selected = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11))
                        Text(p.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Run in a new tab") { store.runPlaybook(p.slug) }
                    Button("Run in background (--auto)") { store.runPlaybook(p.slug, auto: true) }
                } label: {
                    Label("Run", systemImage: "play.fill").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Run this playbook")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if rs.isEmpty {
                Text("No runs yet").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rs) { run in
                            HStack(spacing: 6) {
                                statusDot(run.status)
                                Text(run.slug).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text(run.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func statusDot(_ status: String) -> some View {
        let color: Color = status == "in-progress" ? .green : (status == "done" ? .blue : .gray)
        return Circle().fill(color).frame(width: 6, height: 6)
    }
}
