import FlowBarCore
import SwiftUI

/// Playbooks list → drill into a playbook: its brief, its `updates/` notes and
/// its runs. Read-mostly, with an explicit Run action (spawns a tab).
///
/// A playbook's notes are not second-class to a task's: the brief and the
/// update tiles use the same `MarkdownText` renderer and the same layout as
/// `TaskDetailView`, and each run row carries the same open / view-detail /
/// remind affordances a task row does.
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
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(playbooks) { p in
                            Button {
                                selected = p
                            } label: { row(p) }
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
            Image(systemName: "play.rectangle").font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.slug).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let proj = p.project {
                    Text(proj).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if live > 0 {
                Text("\(live) live").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            }
            Text("\(rs.count) runs").font(.system(size: 13)).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func detail(_ p: Playbook) -> some View {
        let rs = runs(for: p.slug).sorted { $0.slug > $1.slug }  // newest-ish first by slug timestamp
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    selected = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13))
                        Text(p.slug).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                }.buttonStyle(.plain)
                Spacer()
                // The playbook's own brief, beside the action it belongs with.
                // Its runs each carry their own brief button, so the two levels
                // are reachable from the rows they describe rather than from one
                // block of markdown above everything.
                Button { store.peekBrief(p.slug, kind: .playbook) } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View this playbook's brief and notes")
                Menu {
                    Button("Run in a new tab") { store.runPlaybook(p.slug) }
                    Button("Run in background (--auto)") { store.runPlaybook(p.slug, auto: true) }
                } label: {
                    Label("Run", systemImage: "play.fill").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Run this playbook")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            // **Runs first.** You open a playbook to see whether it ran and
            // what it did; the procedure is reference material, and a full
            // brief used to push the runs off the bottom of a 560pt popover.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    runsSection(rs)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func runsSection(_ rs: [PlaybookRun]) -> some View {
        HStack(spacing: 6) {
            Text("RUNS").font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
            Text("\(rs.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        if rs.isEmpty {
            Text("No runs yet").font(.system(size: 14)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rs) { run in runRow(run) }
            }
        }
    }

    /// A run row carries the same three affordances as a task row — open,
    /// view detail, remind. Runs ARE tasks in flow's model (kind=playbook_run),
    /// so `peekBrief` reads the run's snapshotted brief and its own updates,
    /// and `beginReminder` keys on the run slug like any other task.
    private func runRow(_ run: PlaybookRun) -> some View {
        let done = run.status == "done"
        return HStack(spacing: 2) {
            Button { store.switchTo(run.slug) } label: {
                HStack(spacing: 6) {
                    Text(run.slug).font(.system(size: 14)).lineLimit(1)
                    Spacer(minLength: 4)
                    StatusPill(status: run.status)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(done)
            .opacity(done ? 0.7 : 1)
            .help(done ? "Run is done — open its detail to review"
                       : "Open this run in the terminal")

            Button { store.peekBrief(run.slug) } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("View this run's brief and notes")

            Button { store.beginReminder(slug: run.slug, name: run.slug) } label: {
                Image(systemName: "bell")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remind me about this run")
        }
    }

}
