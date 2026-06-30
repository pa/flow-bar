import FlowBarCore
import SwiftUI

/// Owners list → drill into an owner to see its tasks + parked questions.
/// Safe actions only: pause / resume.
struct OwnersView: View {
    @ObservedObject var store: Store
    let query: String

    @State private var selected: Owner?

    var body: some View {
        Group {
            if let o = selected { detail(o) } else { list }
        }
        .onAppear { if store.metrics == nil { store.refreshMetrics() } }
    }

    private var owners: [Owner] {
        let all = store.metrics?.owners ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? all : all.filter { $0.slug.lowercased().contains(q) }
        return filtered.sorted { $0.slug < $1.slug }
    }

    private var list: some View {
        Group {
            if store.metrics == nil, store.metricsLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if owners.isEmpty {
                Text(query.isEmpty ? "No owners" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(owners) { o in
                            Button { selected = o; store.loadOwnerTasks(o.slug) } label: { row(o) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ o: Owner) -> some View {
        HStack(spacing: 8) {
            statusDot(o.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(o.status) · every \(o.every)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let rel = o.nextTickRelative {
                Text(rel).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func detail(_ o: Owner) -> some View {
        let tasks = store.ownerTasks
        let questions = tasks.filter { $0.tagList.contains("question") }
        let others = tasks.filter { !$0.tagList.contains("question") }.sortedByStatusThenPriority()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { selected = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11))
                        Text(o.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Tick now (new tab)") { store.ownerTick(o.slug) }
                    Button("Tick in background (--auto)") { store.ownerTick(o.slug, auto: true) }
                } label: {
                    Label("Tick", systemImage: "bolt.fill").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                .help("Wake this owner now")
                Button {
                    store.setOwnerPaused(o.slug, paused: o.status == "active")
                    selected = nil
                } label: {
                    Label(o.status == "active" ? "Pause" : "Resume",
                          systemImage: o.status == "active" ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text("next tick \(o.nextTickRelative ?? o.nextTick ?? "—")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            Divider()

            if store.ownerTasksLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tasks.isEmpty {
                Text("No tasks managed").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !questions.isEmpty {
                            sectionLabel("Questions for you", questions.count)
                            ForEach(questions) { t in TaskRow(task: t) { store.switchTo(t.slug) } }
                        }
                        if !others.isEmpty {
                            sectionLabel("Managed tasks", others.count)
                            ForEach(others) { t in TaskRow(task: t) { store.switchTo(t.slug) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionLabel(_ title: String, _ n: Int) -> some View {
        Text("\(title.uppercased())  \(n)")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func statusDot(_ status: String) -> some View {
        let color: Color = status == "active" ? .green : (status == "paused" ? .orange : .gray)
        return Circle().fill(color).frame(width: 7, height: 7)
    }
}
