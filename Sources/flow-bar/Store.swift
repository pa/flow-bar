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

    // Dashboard metrics — aggregated from local CLI calls, on demand.
    @Published var metrics: DashboardMetrics?
    @Published var metricsError: String?
    @Published var metricsLoading = false

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
    func startPolling(interval: TimeInterval = 60) {
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

    // Tasks under a drilled-into project.
    @Published var projectTasks: [FlowTask] = []
    @Published var projectTasksLoading = false

    // Playbooks + runs (Playbooks section).
    @Published var playbooks: [Playbook] = []
    @Published var runs: [PlaybookRun] = []
    @Published var playbooksLoading = false

    // Tasks managed by a drilled-into owner.
    @Published var ownerTasks: [FlowTask] = []
    @Published var ownerTasksLoading = false

    // Task list filtered by a non-in-progress status (backlog/done/all).
    // In-progress uses `tasks` (polled live); other filters use this.
    @Published var browseTasks: [FlowTask] = []
    @Published var browseLoading = false

    /// Load tasks for a status filter other than in-progress (nil = all).
    func loadBrowse(status: String?) {
        browseLoading = true
        browseTasks = []
        Task {
            let r = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(status: status)
            }.value) ?? []
            self.browseTasks = r
            self.browseLoading = false
        }
    }

    /// Load playbook definitions + runs for the Playbooks section.
    func refreshPlaybooks() {
        playbooksLoading = true
        Task {
            let pbs = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listPlaybooks()
            }.value) ?? []
            let rns = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listRuns()
            }.value) ?? []
            self.playbooks = pbs
            self.runs = rns
            self.playbooksLoading = false
        }
    }

    /// Run a playbook. `auto` runs headlessly; else spawns a tab.
    func runPlaybook(_ slug: String, auto: Bool = false) {
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().runPlaybook(slug, auto: auto)
            }.value
            self.refreshPlaybooks()
        }
    }

    /// Tick an owner now. `auto` ticks headlessly; else spawns a tab.
    func ownerTick(_ slug: String, auto: Bool = false) {
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().ownerTick(slug, auto: auto)
            }.value
        }
    }

    /// Load all tasks tagged `owner:<slug>` for the owner drill-in.
    func loadOwnerTasks(_ slug: String) {
        ownerTasksLoading = true
        ownerTasks = []
        Task {
            let result = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(tag: "owner:\(slug)")
            }.value) ?? []
            self.ownerTasks = result
            self.ownerTasksLoading = false
        }
    }

    /// Pause/resume an owner (safe), then refresh metrics so status updates.
    func setOwnerPaused(_ slug: String, paused: Bool) {
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().setOwner(slug, paused: paused)
            }.value
            self.refreshMetrics()
        }
    }

    /// Load all tasks under a project (any status) for the Projects drill-in.
    func loadProjectTasks(_ slug: String) {
        projectTasksLoading = true
        projectTasks = []
        Task {
            let result = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(project: slug)
            }.value) ?? []
            self.projectTasks = result
            self.projectTasksLoading = false
        }
    }

    /// Aggregate dashboard metrics (all local CLI calls). On demand.
    func refreshMetrics() {
        metricsLoading = true
        Task {
            do {
                let m = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().dashboardMetrics()
                }.value
                self.metrics = m
                self.metricsError = nil
                // Keep the in-progress list (and icon badge) in sync for free.
                self.tasks = m.inProgress
                self.lastUpdated = Date()
            } catch {
                self.metricsError = String(describing: error)
            }
            self.metricsLoading = false
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
