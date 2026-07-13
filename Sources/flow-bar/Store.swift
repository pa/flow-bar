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
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Revert the toggle if the system rejected it.
                launchAtLogin = oldValue
            }
        }
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

    // In-app updates (see Updater.swift).
    let currentVersion = Updater.currentVersion
    /// Set when a newer release exists; drives the footer "Update" affordance.
    @Published var availableUpdate: Updater.Release?
    enum UpdateStatus: Equatable { case idle, installing, failed(String) }
    @Published var updateStatus: UpdateStatus = .idle
    private var lastUpdateCheck: Date?

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
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastUpdateCheck = Date()
        Task {
            guard let latest = await Updater.fetchLatest() else { return }
            self.availableUpdate = isVersion(latest.version, newerThan: Updater.currentVersion) ? latest : nil
        }
    }

    /// Download + install the available update (app relaunches on success).
    func installUpdate() {
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

    /// flow do's live-session guard: the task's session is already running
    /// elsewhere (it names the running session and points at --force).
    private static func isLiveSessionGuard(_ stderr: String) -> Bool {
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
