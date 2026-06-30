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
    private var activeRefreshTask: Task<Void, Never>?

    /// Menubar icon style preference, persisted across launches.
    @Published var monochromeIcon: Bool = UserDefaults.standard.bool(forKey: "monochromeIcon") {
        didSet { UserDefaults.standard.set(monochromeIcon, forKey: "monochromeIcon") }
    }

    // FLOW_ROOT profiles (see Profiles.swift).
    @Published var profiles: [Profile] = []
    @Published var activeProfileID: String = ""

    /// In-flight operations that actually open a terminal (flow do / flow run
    /// playbook / owner tick — NOT the routine data refreshes). Drives the
    /// menubar loading spinner only.
    @Published var spawningOps = 0

    /// True while a terminal-spawning command is running.
    var isWorking: Bool { spawningOps > 0 }

    /// Bumped each time the popover opens, so the content view can reset its
    /// navigation to the In-progress tab without recreating the view.
    @Published var openNonce = 0

    /// Transient outcome of the last fire-and-forget action (switch / run),
    /// shown briefly on the menubar icon so completion isn't ambiguous.
    enum OpResult: Equatable { case success, failure, alreadyOpen }
    @Published var recentResult: OpResult?
    private var resultResetTask: Task<Void, Never>?

    /// Flash a result on the menubar icon, then clear it.
    func flashResult(_ result: OpResult) {
        recentResult = result
        resultResetTask?.cancel()
        let seconds: UInt64 = result == .success ? 1_600_000_000 : 3_500_000_000
        resultResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds)
            if !Task.isCancelled { self?.recentResult = nil }
        }
    }

    init() {
        loadProfiles()
        // No background polling — refreshing only happens while the popover
        // is open (see beginActiveRefresh).
    }

    /// Number of in-progress tasks that need attention (overdue).
    var attentionCount: Int {
        tasks.filter { $0.isOverdue }.count
    }

    /// Called when the popover opens: refresh now, then every 60s WHILE open.
    func beginActiveRefresh(interval: TimeInterval = 60) {
        refresh()
        refreshMetrics()
        activeRefreshTask?.cancel()
        activeRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                self?.refresh()
                self?.refreshMetrics()
            }
        }
    }

    /// Called when the popover closes: stop refreshing and free cached data so
    /// idle RAM stays low. Nothing runs in the background while closed.
    func endActiveRefresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        tasks = []
        metrics = nil
        projectTasks = []
        ownerTasks = []
        browseTasks = []
        playbooks = []
        runs = []
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
        if !auto { spawningOps += 1 }   // only the new-tab path opens a terminal
        Task {
            let res = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().runPlaybook(slug, auto: auto)
            }.value
            if !auto {
                self.spawningOps -= 1
                self.flashResult((res?.code ?? 1) == 0 ? .success : .failure)
            }
            self.refreshPlaybooks()
        }
    }

    /// Tick an owner now. `auto` ticks headlessly; else spawns a tab.
    func ownerTick(_ slug: String, auto: Bool = false) {
        if !auto { spawningOps += 1 }
        Task {
            let res = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().ownerTick(slug, auto: auto)
            }.value
            if !auto {
                self.spawningOps -= 1
                self.flashResult((res?.code ?? 1) == 0 ? .success : .failure)
            }
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
        // Safe, no-terminal mutation — no menubar loading indicator.
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
        spawningOps += 1
        Task {
            do {
                let res = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().doTask(slug)
                }.value
                self.spawningOps -= 1
                if res.code == 0 {
                    self.errorText = nil
                    self.flashResult(.success)
                } else if Self.isLiveSessionGuard(res.stderr) {
                    // Task is already open in another tab — not a failure.
                    self.errorText = nil
                    self.flashResult(.alreadyOpen)
                } else {
                    self.errorText = "switch to \(slug) failed: \(res.stderr)"
                    self.flashResult(.failure)
                }
            } catch {
                self.spawningOps -= 1
                self.errorText = String(describing: error)
                self.flashResult(.failure)
            }
        }
    }

    /// flow do's live-session guard: the task's session is already running
    /// elsewhere (it names the running session and points at --force).
    private static func isLiveSessionGuard(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("--force") || s.contains("already running")
            || s.contains("running session") || s.contains("already open")
    }

    /// Close the menubar popover so an action feels instant. The AppDelegate
    /// registers a handler that performs the actual NSPopover close.
    static var dismissHandler: (() -> Void)?
    static func dismissPopover() {
        dismissHandler?()
    }
}
