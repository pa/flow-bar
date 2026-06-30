import AppKit
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

    // Dashboard metrics — aggregated from local CLI calls, on demand.
    @Published var metrics: DashboardMetrics?
    @Published var metricsError: String?
    @Published var metricsLoading = false

    private let client = FlowClient()
    private var pollTask: Task<Void, Never>?

    /// Menubar icon style preference, persisted across launches.
    @Published var monochromeIcon: Bool = UserDefaults.standard.bool(forKey: "monochromeIcon") {
        didSet { UserDefaults.standard.set(monochromeIcon, forKey: "monochromeIcon") }
    }

    // FLOW_ROOT profiles (see Profiles.swift).
    @Published var profiles: [Profile] = []
    @Published var activeProfileID: String = ""

    /// In-flight fire-and-forget operations (switch / run / tick) that have no
    /// dedicated loading flag. Combined with the per-section loading flags into
    /// `isBusy`, which drives the menubar spinner.
    @Published var busyOps = 0

    /// True whenever any background flow command is running.
    var isBusy: Bool {
        isLoading || metricsLoading || browseLoading || projectTasksLoading
            || ownerTasksLoading || playbooksLoading || busyOps > 0
    }

    init() {
        loadProfiles()
        startPolling()
    }

    /// Number of in-progress tasks that need attention (overdue) — drives the
    /// menubar icon badge.
    var attentionCount: Int {
        tasks.filter { $0.isOverdue }.count
    }

    /// Refresh on a fixed cadence so the menubar stays current without the
    /// popover being open. Refreshes immediately, then every `interval`.
    func startPolling(interval: TimeInterval = 120) {
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
        busyOps += 1
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().runPlaybook(slug, auto: auto)
            }.value
            self.busyOps -= 1
            self.refreshPlaybooks()
        }
    }

    /// Tick an owner now. `auto` ticks headlessly; else spawns a tab.
    func ownerTick(_ slug: String, auto: Bool = false) {
        busyOps += 1
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().ownerTick(slug, auto: auto)
            }.value
            self.busyOps -= 1
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
        busyOps += 1
        Task {
            _ = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().setOwner(slug, paused: paused)
            }.value
            self.busyOps -= 1
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

    /// Aggregate dashboard metrics. Runs the independent flow reads
    /// CONCURRENTLY (vs. ~8 sequential calls) so the dashboard loads fast.
    func refreshMetrics() {
        metricsLoading = true
        Task {
            let c = FlowClient()
            async let ip       = Task.detached { (try? c.inProgressTasks()) ?? [] }.value
            async let backlog  = Task.detached { (try? c.listTasks(status: "backlog").count) ?? 0 }.value
            async let done     = Task.detached { (try? c.listTasks(status: "done").count) ?? 0 }.value
            async let projects = Task.detached { (try? c.listProjects()) ?? [] }.value
            async let runs     = Task.detached { (try? c.listRuns()) ?? [] }.value
            async let owners   = Task.detached { (try? c.listOwners()) ?? [] }.value
            async let tags     = Task.detached { (try? c.listTags()) ?? [] }.value
            async let questions = Task.detached { (try? c.listTasks(tag: "question")) ?? [] }.value

            let m = DashboardMetrics(
                inProgress: await ip, backlogCount: await backlog, doneCount: await done,
                projects: await projects, runs: await runs, owners: await owners,
                tags: await tags, questions: await questions)
            self.metrics = m
            self.metricsError = nil
            // Keep the in-progress list (and search) in sync for free.
            self.tasks = m.inProgress
            self.lastUpdated = Date()
            self.metricsLoading = false
        }
    }

    /// Switch to a task — `flow do <slug>` focuses its live tab or spawns a
    /// new one. We dismiss the popover IMMEDIATELY (so the click feels
    /// instant) and run `flow do` fire-and-forget in the background; no
    /// post-switch refresh (the next poll/open picks up any change).
    func switchTo(_ slug: String) {
        Self.dismissPopover()
        busyOps += 1
        Task {
            do {
                let res = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().doTask(slug)
                }.value
                // Surface a failure on the next open; don't block the switch.
                self.errorText = res.code != 0 ? "switch to \(slug) failed: \(res.stderr)" : nil
            } catch {
                self.errorText = String(describing: error)
            }
            self.busyOps -= 1
        }
    }

    /// Close the MenuBarExtra popover so an action feels instant.
    /// (The .window-style popover is the key window when a row is clicked.)
    static func dismissPopover() {
        NSApp.keyWindow?.close()
    }
}
