import AppKit
import FlowBarCore
import Foundation
import ServiceManagement

/// Observable view-model backing the menubar UI. macOS 13 compatible
/// (ObservableObject, not the macOS 14 @Observable macro).
///
/// All flow CLI calls are blocking `Process` invocations, so they run on a
/// detached task and publish results back on the main actor.
@MainActor
final class Store: ObservableObject {
    /// Shared instance used by both the AppDelegate and the SwiftUI Settings
    /// scene, so ⌘, and the footer gear open the same populated settings.
    static let shared = Store()

    @Published var tasks: [FlowTask] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var isLoading = false

    // Dashboard metrics — aggregated from local CLI calls, on demand.
    @Published var metrics: DashboardMetrics?
    @Published var metricsError: String?
    @Published var metricsLoading = false

    // flow's own "AI memory" stats (`flow stats`), shown atop the Overview.
    // Kept separate from DashboardMetrics (which is exact-only; these include
    // flow's token/time estimates).
    @Published var stats: FlowStats?

    private let client = FlowClient()
    private var activeRefreshTask: Task<Void, Never>?

    /// Menubar icon style preference, persisted across launches.
    @Published var monochromeIcon: Bool = UserDefaults.standard.bool(forKey: "monochromeIcon") {
        didSet { UserDefaults.standard.set(monochromeIcon, forKey: "monochromeIcon") }
    }

    /// The global toggle shortcut; persisted, and re-registered on change.
    @Published var toggleShortcut: Shortcut = .load() {
        didSet {
            toggleShortcut.save()
            HotKeyManager.shared.register(toggleShortcut)
        }
    }

    /// Start flow-bar at login (SMAppService, macOS 13+). Reflects the live
    /// system state; toggling registers/unregisters the login item.
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard !suppressLaunchAtLoginSideEffect else { return }
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
                FlowClient.log("launch-at-login: \(launchAtLogin ? "register" : "unregister") ok — "
                               + "status now \(Self.describe(SMAppService.mainApp.status))")
            } catch {
                // Previously this reverted the toggle and said NOTHING, so a
                // rejected registration looked like the switch simply refusing
                // to move. Report it instead.
                FlowClient.log("launch-at-login: \(launchAtLogin ? "register" : "unregister") "
                               + "FAILED — \(error)")
                launchAtLoginError = Self.launchAtLoginMessage(for: error)
                suppressLaunchAtLoginSideEffect = true
                launchAtLogin = oldValue
                suppressLaunchAtLoginSideEffect = false
            }
        }
    }

    /// Set while we're writing the toggle to mirror system state, so the
    /// observer doesn't turn a read back into a register/unregister call.
    private var suppressLaunchAtLoginSideEffect = false

    /// Why the last register/unregister failed, or nil. Surfaced in Settings.
    @Published var launchAtLoginError: String?

    /// Re-read the live system state. The toggle's initial value is captured
    /// once when the Store is created, so it goes stale if the user changes it
    /// in System Settings > General > Login Items, or if macOS revokes it.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let enabled = (status == .enabled)
        FlowClient.log("launch-at-login: status=\(Self.describe(status)) "
                       + "bundle=\(Bundle.main.bundlePath)")
        if enabled != launchAtLogin {
            suppressLaunchAtLoginSideEffect = true
            launchAtLogin = enabled
            suppressLaunchAtLoginSideEffect = false
        }
        // `.requiresApproval` means macOS registered it but the user has it
        // switched off in System Settings — the app can't override that.
        launchAtLoginError = (status == .requiresApproval)
            ? "Turn flow-bar on in System Settings › General › Login Items"
            : nil
    }

    nonisolated private static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          return "enabled"
        case .notRegistered:    return "notRegistered"
        case .notFound:         return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default:       return "unknown(\(s.rawValue))"
        }
    }

    nonisolated private static func launchAtLoginMessage(for error: Error) -> String {
        let ns = error as NSError
        // Registering from outside /Applications is the usual cause on a dev
        // build; macOS wants a stable, LaunchServices-registered location.
        if ns.domain == NSOSStatusErrorDomain || ns.code == 1 {
            return "macOS refused it — move flow-bar to /Applications and try again"
        }
        return "macOS refused it: \(ns.localizedDescription)"
    }

    /// Preferred flow terminal backend (FLOW_TERM); "" = let flow auto-detect.
    @Published var terminalBackend: String = UserDefaults.standard.string(forKey: "flowTerm") ?? "" {
        didSet { UserDefaults.standard.set(terminalBackend, forKey: "flowTerm") }
    }

    // FLOW_ROOT profiles (see Profiles.swift).
    @Published var profiles: [Profile] = []
    @Published var activeProfileID: String = ""

    // Brief peek: which task's brief+updates is open (nil = list view), plus
    // the loaded detail and its loading flag. Reads markdown files, no flow.db.
    @Published var peekedSlug: String?
    @Published var taskDetail: TaskDetail?
    @Published var taskDetailLoading = false

    /// In-flight operations that actually open a terminal (flow do / flow run
    /// playbook / owner tick — NOT the routine data refreshes). Drives the
    /// menubar loading spinner only.
    @Published var spawningOps = 0

    /// True while a terminal-spawning command is running.
    var isWorking: Bool { spawningOps > 0 }

    /// Bumped each time the popover opens, so the content view can reset its
    /// navigation to the In-progress tab without recreating the view.
    @Published var openNonce = 0

    // MARK: Multi-select

    /// Slugs the user has ticked for a batch open.
    ///
    /// SLUGS, not tasks, and deliberately NOT pruned when the list reloads: the
    /// slug is all `flow do` needs, so a check survives the list being replaced
    /// by a poll or narrowed by a new search. That survival IS the feature —
    /// the user ticks a couple, re-searches, ticks a couple more, opens all.
    ///
    /// Lives on Store rather than in TasksView because every point that
    /// invalidates it is here: `endActiveRefresh()` (popover close) and
    /// `reloadForProfileSwitch()` (FLOW_ROOT change — reachable from the footer
    /// WITHOUT closing the popover, so a view-owned set would happily fire
    /// slugs from one root against another).
    @Published var selectedTaskSlugs: Set<String> = []

    /// Deterministic batch order, so logs and error text are stable.
    var orderedSelection: [String] { selectedTaskSlugs.sorted() }

    func toggleSelection(_ slug: String) {
        if selectedTaskSlugs.contains(slug) { selectedTaskSlugs.remove(slug) }
        else { selectedTaskSlugs.insert(slug) }
    }

    func clearSelection() { selectedTaskSlugs = [] }

    // In-app updates (see Updater.swift).
    let currentVersion = Updater.currentVersion
    /// Set when a newer release exists; drives the footer "Update" affordance.
    @Published var availableUpdate: Updater.Release?
    enum UpdateStatus: Equatable { case idle, installing, failed(String) }
    @Published var updateStatus: UpdateStatus = .idle
    private var lastUpdateCheck: Date?

    /// Homebrew compiled and owns this install, so the app must not swap its own
    /// bundle — doing so would replace an SDK-native binary with a CI-built one.
    /// The UI offers the `brew upgrade` command instead of an Install button.
    var isManagedInstall: Bool { Updater.isManagedInstall }

    /// True when the running OS is newer than the SDK this binary was built
    /// against — the UI is in compatibility mode and a rebuild would fix it.
    /// Without this nudge a user who upgrades macOS keeps the stale build forever.
    var needsSDKRebuild: Bool { AppInfo.isManagedInstall && AppInfo.sdkIsBehindOS }

    /// Copy a shell command to the pasteboard (used by the update affordances).
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashResult(.success)
    }

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
        loadReminders()
        wireReminderScheduler()
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
        checkForUpdate()
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
        selectedTaskSlugs = []
        tasks = []
        metrics = nil
        stats = nil
        closePeek()
        cancelCreate()
        tagTasks = []
        projectTasks = []
        ownerTasks = []
        browseTasks = []
        playbooks = []
        runs = []
        reminderLinkTasks = []
    }

    /// Check GitHub for a newer release (throttled to once/hour unless forced).
    func checkForUpdate(force: Bool = false) {
        // An untagged local build reports 0.0.0-dev, so every release looks
        // newer — it would nag on every launch. Nothing to update to anyway.
        guard !AppInfo.isDevBuild else { return }
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastUpdateCheck = Date()
        Task {
            guard let latest = await Updater.fetchLatest() else { return }
            self.availableUpdate = isVersion(latest.version, newerThan: Updater.currentVersion) ? latest : nil
        }
    }

    /// Download + install the available update (app relaunches on success).
    /// On a Homebrew source install this copies the `brew upgrade` command
    /// instead — see `Updater`'s type comment for why self-installing is wrong
    /// there.
    func installUpdate() {
        if isManagedInstall { copyToPasteboard(Updater.upgradeCommand); return }
        guard let rel = availableUpdate, updateStatus != .installing else { return }
        updateStatus = .installing
        Task {
            do { try await Updater.install(rel) }        // success → app quits & relaunches
            catch { self.updateStatus = .failed("\(error)") }
        }
    }

    /// Open the brief peek for a task and load its brief + recent updates.
    func peekBrief(_ slug: String) {
        peekedSlug = slug
        taskDetail = nil
        taskDetailLoading = true
        Task {
            let d = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().taskDetail(slug)
            }.value
            // Ignore if the user closed the peek or opened a different one.
            guard self.peekedSlug == slug else { return }
            self.taskDetail = d
            self.taskDetailLoading = false
        }
    }

    /// Close the brief peek and return to the list.
    func closePeek() {
        peekedSlug = nil
        taskDetail = nil
        taskDetailLoading = false
    }

    // MARK: Create (task intake)

    @Published var isCreating = false
    @Published var creatingBusy = false
    @Published var createError: String?
    /// Existing slugs (incl. archived) so the form can block duplicates — slug
    /// is flow's primary key. Loaded when the create form opens.
    @Published var existingTaskSlugs: Set<String> = []
    @Published var existingProjectSlugs: Set<String> = []
    /// Projects available to attach a task to (for the picker).
    @Published var pickerProjects: [Project] = []
    /// Existing tag names (excludes auto-managed owner:* tags) for the picker.
    @Published var pickerTags: [String] = []

    /// Open the create form and load existing slugs/projects/tags.
    func beginCreate() {
        createError = nil
        creatingBusy = false
        isCreating = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([String], [Project], [String]) in
                let c = FlowClient()
                let slugs = ((try? c.listTasks(includeArchived: true)) ?? []).map(\.slug)
                let projects = (try? c.listProjects()) ?? []
                let tags = ((try? c.listTags()) ?? []).map(\.tag).filter { !$0.hasPrefix("owner:") }
                return (slugs, projects, tags)
            }.value
            self.existingTaskSlugs = Set(loaded.0)
            self.pickerProjects = loaded.1
            self.existingProjectSlugs = Set(loaded.1.map(\.slug))
            self.pickerTags = loaded.2
        }
    }

    func cancelCreate() {
        isCreating = false
        creatingBusy = false
        createError = nil
    }

    /// Create a task (optionally creating a new project first — flow requires
    /// `--project` to already exist). On success, close the form and refresh.
    func createTask(name: String, slug: String,
                    existingProject: String?,
                    newProject: (name: String, slug: String, workDir: String, mkdir: Bool)?,
                    priority: String, tags: [String], due: String,
                    workDir: String, mkdir: Bool, brief: String) {
        creatingBusy = true
        createError = nil
        Task {
            do {
                // Resolve the project slug, creating the project first if new.
                let projectSlug: String? = try await Task.detached(priority: .userInitiated) { () -> String? in
                    let c = FlowClient()
                    if let np = newProject {
                        _ = try c.createProject(name: np.name, slug: np.slug, workDir: np.workDir,
                                                priority: "medium", mkdir: np.mkdir, brief: "")
                        return np.slug
                    }
                    return existingProject
                }.value
                _ = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().createTask(
                        name: name, slug: slug, project: projectSlug,
                        workDir: workDir.isEmpty ? nil : workDir, priority: priority,
                        due: due.isEmpty ? nil : due, tags: tags, mkdir: mkdir, brief: brief)
                }.value
                self.creatingBusy = false
                self.isCreating = false
                self.refresh()
                self.refreshMetrics()
            } catch {
                self.creatingBusy = false
                self.createError = String(describing: error)
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

    /// Load only archived tasks (hidden from the normal lists). Uses
    /// `--include-archived` and keeps the ones flagged archived.
    func loadArchived() {
        browseLoading = true
        browseTasks = []
        Task {
            let r = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(includeArchived: true)
            }.value) ?? []
            self.browseTasks = r.filter { $0.isArchived }
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

    // Tasks for a drilled-into tag (Tags section).
    @Published var tagTasks: [FlowTask] = []
    @Published var tagTasksLoading = false
    /// Set by a dashboard top-tag tap so the Tags section opens pre-drilled.
    @Published var pendingTagDrill: String?

    /// Load all tasks carrying a given tag (any status) for the Tags drill-in.
    func loadTagTasks(_ tag: String) {
        tagTasksLoading = true
        tagTasks = []
        Task {
            let r = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(tag: tag)
            }.value) ?? []
            self.tagTasks = r
            self.tagTasksLoading = false
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
            async let stats    = Task.detached { try? c.flowStats() }.value

            let m = DashboardMetrics(
                inProgress: await ip, backlogCount: await backlog, doneCount: await done,
                projects: await projects, runs: await runs, owners: await owners,
                tags: await tags, questions: await questions)
            self.metrics = m
            self.stats = await stats
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

    // MARK: Batch open

    private enum BatchOutcome: Sendable { case ok, alreadyOpen, failed(String) }

    /// Pause between spawns in a multi-open, to let each new tab's harness
    /// session finish starting before the next tab steals the terminal.
    /// Empirical, not principled: `flow do` gives us no "session is ready"
    /// signal to wait on, so this is the smallest gap that reliably let a
    /// Claude session come up before the next spawn.
    private static let multiOpenSettleNanos: UInt64 = 1_200_000_000  // 1.2s

    /// Open several tasks at once. All `flow do` calls run in PARALLEL.
    func switchToAll(_ slugs: [String]) {
        // Snapshot BEFORE dismissing. `dismissPopover()` synchronously triggers
        // popoverDidClose -> endActiveRefresh(), which wipes `tasks` AND
        // `selectedTaskSlugs` — so reading the selection after the dismiss reads
        // an empty set. This `let` is load-bearing.
        let batch = slugs
        guard !batch.isEmpty else { return }
        // One task: reuse the proven single path (its flash/error handling is
        // already exactly right, and there is nothing to aggregate).
        if batch.count == 1 { switchTo(batch[0]); return }

        FlowClient.log("multi-open: opening \(batch.count) sequentially — \(batch.joined(separator: ", "))")
        selectedTaskSlugs = []
        Self.dismissPopover()
        spawningOps += batch.count   // counter, so the spinner spans the batch

        Task {
            var succeeded = 0, alreadyOpen = 0
            var failures: [(slug: String, message: String)] = []

            // SEQUENTIAL, not parallel — and this is deliberate.
            //
            // `flow do` returns once it has CREATED the terminal tab, not once
            // the harness session inside it has finished starting. Firing the
            // batch in parallel therefore raced: a second tab opened while the
            // first was still bootstrapping its Claude session, the two
            // interleaved, and neither came up properly. (Observed with the
            // zellij backend; the AppleScript backends are worse, since several
            // concurrent `osascript` clients driving one terminal can also land
            // tabs in the wrong window.)
            //
            // So each task gets the terminal to itself: open it, wait for
            // `flow do` to return, then let the session settle before the next.
            for slug in batch {
                let outcome = await Self.doTaskOffThread(slug)
                self.spawningOps -= 1
                switch outcome {
                case .ok:            succeeded += 1
                case .alreadyOpen:   alreadyOpen += 1
                case .failed(let m): failures.append((slug, m))
                }
                FlowClient.log("multi-open: \(slug) -> \(outcome)")
                // Settle gap, skipped after the last one so the batch doesn't
                // end on a pointless wait. Only needed when a tab was actually
                // spawned — switching to an already-open tab is instant.
                if slug != batch.last, case .ok = outcome {
                    try? await Task.sleep(nanoseconds: Self.multiOpenSettleNanos)
                }
            }

            // ONE flash, not N. `flashResult` cancels and restarts its reset
            // task on every call, so N calls would strobe and end on whichever
            // spawn happened to finish last.
            FlowClient.log("multi-open: done — \(succeeded) opened, \(alreadyOpen) already open, "
                           + "\(failures.count) failed")
            if failures.isEmpty {
                self.errorText = nil
                // Everything was already open: say so, otherwise a batch that
                // worked perfectly is indistinguishable from one that did
                // nothing — especially with zellij, where "switch tab" is
                // invisible unless the terminal is already frontmost.
                if succeeded == 0 {
                    self.errorText = alreadyOpen == 1
                        ? "already open — switched to its tab"
                        : "all \(alreadyOpen) were already open — switched to the last one"
                }
                self.flashResult(succeeded == 0 ? .alreadyOpen : .success)
            } else {
                self.errorText = Self.batchErrorText(
                    total: batch.count, opened: succeeded + alreadyOpen, failures: failures)
                self.flashResult(.failure)
            }
        }
    }

    /// Run the blocking `flow do` off the cooperative thread pool.
    ///
    /// `doTask` -> `spawnDisclaimed` blocks on `waitpid`. `Task.detached` still
    /// runs on the cooperative pool, which is width-limited to roughly the core
    /// count — so N blocked threads would serialise the "parallel" batch and
    /// stall `refresh`/`Updater` behind it. GCD overcommits threads for exactly
    /// this kind of blocking work.
    ///
    /// Carries a `String`, not an `Error`: `Result<_, Error>` won't cross the
    /// concurrency boundary under Swift 6 strict checking.
    nonisolated private static func doTaskOffThread(_ slug: String) async -> BatchOutcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let res = try FlowClient().doTask(slug)
                    if res.code == 0 { cont.resume(returning: .ok) }
                    else if isLiveSessionGuard(res.stderr) { cont.resume(returning: .alreadyOpen) }
                    else { cont.resume(returning: .failed(res.stderr)) }
                } catch {
                    cont.resume(returning: .failed(String(describing: error)))
                }
            }
        }
    }

    nonisolated private static func batchErrorText(
        total: Int, opened: Int, failures: [(slug: String, message: String)]
    ) -> String {
        let names = failures.map(\.slug).joined(separator: ", ")
        // The most likely cause of a batch failure on a first run, and one the
        // user cannot guess from a raw stderr dump.
        if failures.contains(where: { isAutomationDenied($0.message) }) {
            return "opened \(opened) of \(total). macOS hasn't granted Automation yet — "
                 + "open one task on its own first, allow the prompt, then try Open all. "
                 + "(failed: \(names))"
        }
        return "opened \(opened) of \(total) — failed: \(names)"
    }

    /// macOS refused the Apple event. Common when several AppleScript terminal
    /// spawns race before the Automation grant exists; -1743 is the TCC denial.
    nonisolated private static func isAutomationDenied(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("-1743") || s.contains("not allowed") || s.contains("not authorized")
            || s.contains("not permitted")
    }

    /// flow do's live-session guard: the task's session is already running
    /// elsewhere (it names the running session and points at --force).
    nonisolated private static func isLiveSessionGuard(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("--force") || s.contains("already running")
            || s.contains("running session") || s.contains("already open")
    }

    // MARK: Reminders (local notifications)

    private static let remindersKey = "reminders"

    /// User-set reminders (standalone or task-linked), persisted across
    /// launches. Not cleared by endActiveRefresh — these are durable state,
    /// not fetched data.
    @Published var reminders: [Reminder] = []
    /// A reminder to focus when the Reminders section opens — set by a
    /// notification tap (mirrors `pendingTagDrill`), consumed on open.
    @Published var pendingReminderID: UUID?
    /// Seed for the compose form — set by the header ＋ or a task's "Remind me"
    /// bell; RemindersView opens the form pre-filled and clears it.
    @Published var pendingReminderDraft: ReminderDraft?
    /// True when the system has denied notification permission, so the UI can
    /// prompt the user to enable it.
    @Published var notificationsDenied = false

    /// Prefill for the reminder compose form.
    struct ReminderDraft: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var note: String
        var fireDate: Date
        var tasks: [LinkedTask] = []
    }

    /// Default first-nudge time: this evening, or +1h if that's already past.
    private func defaultReminderDate() -> Date {
        let evening = ReminderPreset.thisEvening.date(from: Date()) ?? Date().addingTimeInterval(3600)
        return evening > Date() ? evening : Date().addingTimeInterval(3600)
    }

    /// Open the compose form for a standalone reminder.
    func beginReminderBlank() {
        pendingReminderDraft = ReminderDraft(
            title: "", note: "", fireDate: defaultReminderDate(), tasks: [])
    }

    /// Open the compose form pre-linked to a task (from the row/peek bell).
    /// Defaults the time to the task's due date (09:00) when it has one.
    func beginReminder(slug: String, name: String, dueInDays: Int? = nil) {
        var when = defaultReminderDate()
        if let d = dueInDays,
           let day = Calendar.current.date(byAdding: .day, value: d, to: Date()),
           let at9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day),
           at9 > Date() {
            when = at9
        }
        let display = name.isEmpty ? slug : name
        pendingReminderDraft = ReminderDraft(
            title: display, note: "", fireDate: when,
            tasks: [LinkedTask(slug: slug, name: display, profileID: activeProfileID)])
    }

    func beginReminder(for task: FlowTask) {
        beginReminder(slug: task.slug, name: task.name, dueInDays: task.dueInDays)
    }

    /// Schedules/handles the actual local notifications (app-layer, OS-bound).
    let reminderScheduler = ReminderScheduler()

    /// Tasks a reminder can be linked to — in-progress + backlog (the
    /// actionable ones). Loaded when the Reminders section/compose opens.
    @Published var reminderLinkTasks: [FlowTask] = []

    func loadReminderLinkTasks() {
        Task {
            let all = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(status: nil)   // all non-archived
            }.value) ?? []
            self.reminderLinkTasks = all
                .filter { $0.status == "in-progress" || $0.status == "backlog" }
                .sorted { a, b in
                    let ra = a.status == "in-progress" ? 0 : 1
                    let rb = b.status == "in-progress" ? 0 : 1
                    return ra != rb ? ra < rb : a.slug < b.slug
                }
        }
    }

    private func loadReminders() {
        if let data = UserDefaults.standard.data(forKey: Self.remindersKey) {
            reminders = ReminderStore.decode(data)
        }
    }

    private func persistReminders() {
        if let data = ReminderStore.encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.remindersKey)
        }
    }

    /// Route notification taps/actions from the scheduler back into the app.
    private func wireReminderScheduler() {
        reminderScheduler.onOpen = { id in
            Store.openReminderHandler?(id)   // show popover focused on this reminder
        }
        reminderScheduler.onSnooze = { [weak self] id in
            self?.snoozeReminder(id: id, by: 3600)
        }
        reminderScheduler.onComplete = { [weak self] id in
            self?.completeReminder(id: id)
        }
        reminderScheduler.onAuthDenied = { [weak self] denied in
            self?.notificationsDenied = denied
        }
    }

    /// Re-register the login prompt + re-sync scheduled notifications. Called
    /// on launch by the AppDelegate.
    func reconcileReminders() {
        reminderScheduler.reconcile(reminders)
    }

    func addReminder(_ r: Reminder) {
        reminders.append(r)
        persistReminders()
        reminderScheduler.requestAuthorizationIfNeeded()
        reminderScheduler.reconcile(reminders)
    }

    func updateReminder(_ r: Reminder) {
        guard let i = reminders.firstIndex(where: { $0.id == r.id }) else { return }
        reminders[i] = r
        persistReminders()
        reminderScheduler.reconcile(reminders)
    }

    func completeReminder(id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].completedAt = Date()
        persistReminders()
        reminderScheduler.reconcile(reminders)
    }

    func uncompleteReminder(id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].completedAt = nil
        persistReminders()
        reminderScheduler.reconcile(reminders)
    }

    func deleteReminder(id: UUID) {
        reminders.removeAll { $0.id == id }
        persistReminders()
        reminderScheduler.reconcile(reminders)
    }

    /// Push a reminder's fire time out by `seconds` from now (used by the
    /// notification "Snooze" action and the in-app snooze menu).
    func snoozeReminder(id: UUID, by seconds: TimeInterval) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].fireDate = Date().addingTimeInterval(seconds)
        reminders[i].completedAt = nil
        persistReminders()
        reminderScheduler.reconcile(reminders)
    }

    /// Explicit user action from the Reminders view: open a linked task,
    /// switching flow root first if it lives under a different profile.
    func openLinkedTask(_ t: LinkedTask) {
        if let pid = t.profileID, pid != activeProfileID,
           profiles.contains(where: { $0.id == pid }) {
            setActiveProfile(pid)
        }
        switchTo(t.slug)
    }

    /// The AppDelegate registers this to show the popover focused on a
    /// reminder when a notification is tapped from a closed state.
    static var openReminderHandler: ((UUID) -> Void)?

    /// Close the menubar popover so an action feels instant. The AppDelegate
    /// registers a handler that performs the actual NSPopover close.
    static var dismissHandler: (() -> Void)?
    static func dismissPopover() {
        dismissHandler?()
    }

    /// Open the Settings window. The AppDelegate registers the actual opener.
    static var openSettingsHandler: (() -> Void)?
    static func openSettings() {
        openSettingsHandler?()
    }
}
