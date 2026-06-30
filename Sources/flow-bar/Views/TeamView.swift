import FlowBarCore
import SwiftUI

/// Org-wide "who's doing what" from flow-workspace, grouped by member.
/// Degrades gracefully when the workspace endpoint is unreachable.
struct TeamView: View {
    @ObservedObject var store: Store

    var body: some View {
        Group {
            if store.teamLoading && store.teamMembers.isEmpty {
                loading
            } else if let error = store.teamError, store.teamMembers.isEmpty {
                unavailable(error)
            } else if store.teamMembers.isEmpty {
                centered("No team activity")
            } else {
                list
            }
        }
        .onAppear {
            if store.teamMembers.isEmpty { store.refreshTeam() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.teamMembers) { member in
                    Text(member.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    ForEach(member.tasks) { task in
                        HStack(spacing: 6) {
                            Text(task.slug)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let project = task.project {
                                Text(project)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading team activity…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Workspace unavailable")
                .font(.system(size: 12, weight: .medium))
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
            Button("Retry") { store.refreshTeam() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 16)
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
