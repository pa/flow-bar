import FlowBarCore
import Foundation

/// Observable view-model backing the menubar UI. macOS 13 compatible
/// (ObservableObject, not the macOS 14 @Observable macro).
///
/// All flow CLI calls are blocking `Process` invocations, so they run on a
/// detached task and publish results back on the main actor.
@MainActor
final class Store: ObservableObject {
    @Published var tasks: [FlowTask] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var isLoading = false

    // Team (flow-workspace activity) — loaded on demand, not polled.
    @Published var teamMembers: [TeamMember] = []
    @Published var teamError: String?
    @Published var teamLoading = false

    private let client = FlowClient()
    private var pollTask: Task<Void, Never>?

    init() {
        startPolling()
    }

    /// Number of in-progress tasks that need attention (overdue) — drives the
    /// menubar icon badge.
    var attentionCount: Int {
        tasks.filter { $0.isOverdue }.count
    }

    /// Refresh on a fixed cadence so the menubar stays current without the
    /// popover being open. Refreshes immediately, then every `interval`.
    func startPolling(interval: TimeInterval = 20) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Reload the in-progress task list.
    func refresh() {
        isLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().inProgressTasks()
                }.value
                self.tasks = result
                self.errorText = nil
                self.lastUpdated = Date()
            } catch {
                self.errorText = String(describing: error)
            }
            self.isLoading = false
        }
    }

    /// Load team activity (network call). On-demand only; degrades to an
    /// error message the UI can show without blocking the rest of the app.
    func refreshTeam() {
        teamLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().teamActivity()
                }.value
                self.teamMembers = result
                self.teamError = nil
            } catch {
                self.teamError = String(describing: error)
            }
            self.teamLoading = false
        }
    }

    /// Switch to a task — `flow do <slug>` focuses its live tab or spawns a
    /// new one. (Phase 3 will add search + richer guard/Accessibility
    /// surfacing; Phase 2 wires the basic action + error reporting.)
    func switchTo(_ slug: String) {
        Task {
            do {
                let res = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().doTask(slug)
                }.value
                if res.code != 0 {
                    self.errorText = "switch to \(slug) failed: \(res.stderr)"
                } else {
                    self.errorText = nil
                }
            } catch {
                self.errorText = String(describing: error)
            }
            self.refresh()
        }
    }
}
