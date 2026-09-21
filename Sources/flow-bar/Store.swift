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

    /// Watch live harness sessions and badge the menubar when one is blocked
    /// waiting for you.
    ///
    /// Off by default: it is the one part of the app that observes anything
    /// while the popover is closed (a kqueue watch per live session), so it is
    /// opt-in rather than something a user discovers running. `AppDelegate`
    /// observes this and starts/stops `sessionMonitor` to match.
    @Published var sessionAlertsEnabled: Bool =
        UserDefaults.standard.bool(forKey: "sessionAlertsEnabled")
    {
        didSet { UserDefaults.standard.set(sessionAlertsEnabled, forKey: "sessionAlertsEnabled") }
    }

    /// Breathe the menubar icon while a session is blocked, rather than just
    /// tinting it.
    ///
    /// **On by default, and separable from the alert itself.** Motion is what
    /// makes the icon catch a glance in a row of small coloured glyphs — but
    /// it's also the part that can grate, and some people will want the signal
    /// without the movement. Turning this off keeps the orange tint, so no
    /// information is lost; only the animation stops.
    @Published var sessionAlertPulse: Bool = Store.loadPulsePreference() {
        didSet { UserDefaults.standard.set(sessionAlertPulse, forKey: "sessionAlertPulse") }
    }

    /// Defaults to true when never set.
    ///
    /// `bool(forKey:)` can't express that — it returns false for a missing key,
    /// which would make the default off. Reading the raw object distinguishes
    /// "absent" from "explicitly false", and does so without depending on a
    /// `register(defaults:)` call having already run, which matters because the
    /// Store is built before `applicationDidFinishLaunching`.
    private static func loadPulsePreference() -> Bool {
        UserDefaults.standard.object(forKey: "sessionAlertPulse") as? Bool ?? true
    }

    /// Watches the transcripts behind live tasks. Owned by the Store so both
    /// Settings and the Needs-you section can read it without reaching into the
    /// AppDelegate.
    let sessionMonitor = SessionMonitor()

    /// Set just before the popover opens when a session is blocked, so
    /// `MenuContentView.prepareForOpen` lands on Needs-you instead of the
    /// In-progress list. Same mechanism as `pendingReminderID`.
    @Published var pendingAttention = false

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

    /// The newest SDK this machine can build against. Probed once — it spawns
    /// `xcrun`, and it cannot change while the app is running.
    private lazy var availableSDK: String? = AppInfo.availableSDKVersion()

    /// True when a rebuild would actually produce a newer-SDK binary.
    ///
    /// **Being behind the OS is not sufficient.** Apple ships a new macOS months
    /// before the Xcode carrying its SDK, so anyone who upgrades early is behind
    /// with nothing to do about it — and this prompt used to sit in their footer
    /// permanently, asking for a rebuild that produces the same binary. Measured
    /// on macOS 27.0 with the newest available SDK at 26.5. Advice that cannot
    /// be taken teaches people to ignore the footer.
    var needsSDKRebuild: Bool {
        AppInfo.isManagedInstall
            && SDKFreshness.shouldRebuild(
                buildSDK: AppInfo.buildSDK,
                availableSDK: availableSDK,
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

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
        refreshPalette()
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
        clearPlaybookDetail()
        reminderLinkTasks = []
        // The palette's index is the largest thing we hold — every task in
        // flow, not just the live ones. It goes with the rest.
        allTasks = []
        palette = PaletteIndex()
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

    /// Install the available update. The app quits and comes back either way.
    ///
    /// Two different mechanisms, because the right answer depends on how the app
    /// got here. A `.dmg`/`.zip` install swaps in the released bundle. A
    /// Homebrew source install instead **runs `brew upgrade` for you** — one
    /// click, same as the other path, but the work is done by brew so the build
    /// stays native and keeps this machine's signing identity. Installing the
    /// released zip over a source install would silently kill the Automation
    /// grant and de-nativise the UI; see `BrewUpgrade` for the full reasoning.
    func installUpdate() {
        guard updateStatus != .installing else { return }
        if isManagedInstall {
            updateStatus = .installing
            if !BrewUpgradeRunner.start() {
                // Never quit on a failed launch — that would leave nothing
                // running and nothing explaining why.
                updateStatus = .failed("couldn't start the upgrade — see "
                                       + "~/Library/Logs/flow-bar.log")
            }
            return
        }
        guard let rel = availableUpdate else { return }
        updateStatus = .installing
        Task {
            do { try await Updater.install(rel) }        // success → app quits & relaunches
            catch { self.updateStatus = .failed("\(error)") }
        }
    }

    /// Report how the last brew upgrade went.
    ///
    /// The app isn't running when the result is known — brew quits it and the
    /// script relaunches it — so the outcome arrives as a marker file read at
    /// startup rather than as the return value of anything.
    func reportLastUpgradeResult() {
        switch BrewUpgradeRunner.consumeLastResult() {
        case .ok:
            flashResult(.success)
            FlowClient.log("brew-upgrade: previous run succeeded (now v\(currentVersion))")
        case .failed:
            updateStatus = .failed("the last brew upgrade failed — see "
                                   + "~/Library/Logs/flow-bar-upgrade.log")
            FlowClient.log("brew-upgrade: previous run FAILED")
        case nil:
            break   // no upgrade has run, or its result was already reported
        }
    }

    /// Open the brief peek for a task and load its brief + recent updates.
    /// Which kind of thing the open brief belongs to.
    ///
    /// A task and a playbook both have a `brief.md` and `updates/`, and the
    /// peek renders them identically — but they are read with different `flow
    /// show` subcommands, so the caller has to say which.
    enum PeekKind: Equatable { case task, playbook }

    func peekBrief(_ slug: String, kind: PeekKind = .task) {
        peekedSlug = slug
        taskDetail = nil
        taskDetailLoading = true
        Task {
            let d = try? await Task.detached(priority: .userInitiated) {
                let client = FlowClient()
                return kind == .playbook ? try client.playbookDetail(slug)
                                         : try client.taskDetail(slug)
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
                self.rebuildPalette()
            } catch {
                self.errorText = String(describing: error)
            }
            self.isLoading = false
        }
    }

    // MARK: - Palette (the search-first root)

    /// Every task, whatever its status — the palette searches what the section
    /// views browse. The polled `tasks` list is in-progress only, which is the
    /// right set for the home list and the wrong one for search: a task you
    /// half-remember is most often one you are *not* in the middle of.
    @Published var allTasks: [FlowTask] = []

    /// The ranked index behind the search root. Rebuilt from whatever has
    /// loaded, never awaited — see `rebuildPalette`.
    @Published private(set) var palette = PaletteIndex()
    @Published var paletteLoading = false

    /// The jump list — tasks you pinned to ⌘1…⌘9.
    ///
    /// Persisted, because a number that changes between launches is not a
    /// reflex. Kept per flow root: two roots are two bodies of work, and ⌘2
    /// meaning different things in each is correct.
    @Published var jumpList: JumpList = Store.loadJumpList(UserDefaults.standard.string(forKey: "activeProfile") ?? Profile.defaultID) {
        didSet { saveJumpList() }
    }

    private var jumpListKey: String { "jumpList.\(activeProfileID.isEmpty ? Profile.defaultID : activeProfileID)" }

    private static func loadJumpList(_ profileID: String) -> JumpList {
        let key = "jumpList.\(profileID.isEmpty ? Profile.defaultID : profileID)"
        return JumpList(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private func saveJumpList() {
        UserDefaults.standard.set(jumpList.slugs, forKey: jumpListKey)
    }

    /// Pin or unpin a task, and say what happened.
    /// Copy a task's brief and notes.
    ///
    /// Async because the text isn't in memory until someone asks: the palette
    /// only loads a brief when you open one. The flash is the acknowledgement —
    /// a copy that takes a moment and says nothing reads as a copy that failed.
    func copyBrief(_ slug: String) {
        Task {
            let detail = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().taskDetail(slug)
            }.value
            guard let detail, !detail.clipboardText.isEmpty else {
                self.flashResult(.failure)
                return
            }
            self.copyToPasteboard(detail.clipboardText)
        }
    }

    /// Whether a slug is still something `flow do` could switch to.
    func isOpenable(_ slug: String) -> Bool {
        allTasks.first { $0.slug == slug }?.canOpen
            ?? tasks.first { $0.slug == slug }?.canOpen
            ?? true   // not loaded yet — don't refuse on missing information
    }

    @discardableResult
    func toggleJump(_ slug: String) -> JumpList.Change {
        var list = jumpList
        let change = list.toggle(slug)
        if change != .full { jumpList = list }
        rebuildPalette()
        return change
    }

    // MARK: Release notes

    /// The version whose notes the user has already seen.
    private static let seenReleaseKey = "seenReleaseVersion"

    /// A version worth announcing, or nil.
    ///
    /// **Only on an upgrade, never on a first run.** With nothing recorded we
    /// record silently: a fresh install has nothing to announce, and opening
    /// with "what's new" would be telling someone what changed about software
    /// they have never used.
    @Published private(set) var unreadRelease: String?

    func refreshUnreadRelease() {
        let current = currentVersion
        // Notes that describe a different version are worse than none: the
        // banner would name this build and the document would describe another.
        guard AppInfo.releaseNotesMatchBuild, !AppInfo.isDevBuild else {
            unreadRelease = nil
            return
        }
        let seen = UserDefaults.standard.string(forKey: Self.seenReleaseKey)
        guard let seen else {
            UserDefaults.standard.set(current, forKey: Self.seenReleaseKey)
            unreadRelease = nil
            return
        }
        unreadRelease = (seen == current) ? nil : current
    }

    /// Opening the notes is what retires the banner.
    func markReleaseNotesSeen() {
        UserDefaults.standard.set(currentVersion, forKey: Self.seenReleaseKey)
        unreadRelease = nil
        rebuildPalette()
    }

    /// Whether a task's harness session is running right now.
    ///
    /// Decides whether to offer "skip permission prompts": on a live task the
    /// flag is inert, because `flow do` focuses the existing tab and returns
    /// before it ever builds a command line.
    func hasLiveSession(_ slug: String) -> Bool {
        if let t = allTasks.first(where: { $0.slug == slug }) { return t.isLive }
        if let t = tasks.first(where: { $0.slug == slug }) { return t.isLive }
        return false
    }

    /// The task at a 1-based jump position, if it still exists.
    func jumpTarget(_ number: Int) -> String? { jumpList.slug(at: number) }

    // MARK: Search memo

    /// Bumped whenever anything the palette ranks over changes.
    private var paletteVersion = 0
    private var memoKey: String?
    private var memoResults: PaletteResults?

    /// Memoised ranking for one (place, query) pair.
    ///
    /// **The view asks for its results about fifteen times per render** — the
    /// list, the height, the cursor, the footer label, the ⌘K actions and every
    /// `selected` helper all derive from them — and each ask was re-ranking the
    /// whole index, rebuilding a route's rows from tasks first. The answer
    /// cannot change within a render, so it is computed once.
    ///
    /// Keyed by the place as well as the query, because "" means the home list
    /// at the root and "all of it" inside a route. The version invalidates it
    /// whenever the underlying rows change, so a stale answer cannot outlive a
    /// refresh.
    func memoisedResults(key: String, query: String,
                         _ compute: () -> PaletteResults) -> PaletteResults {
        let full = "\(paletteVersion)|\(key)|\(query)"
        if memoKey == full, let memoResults { return memoResults }
        let results = compute()
        memoKey = full
        memoResults = results
        return results
    }

    /// Call when anything the palette ranks over changes.
    func invalidatePaletteSearch() {
        paletteVersion &+= 1
        memoKey = nil
        memoResults = nil
    }

    /// True while the palette is showing a document — a brief, or the release
    /// notes — rather than a list.
    ///
    /// The jump panel reads this: a list of nine other tasks sliding in under
    /// something you are *reading* is out of place, and ⌘ is busy there (⌘C to
    /// copy, ⌘K for actions). The keys keep working; only the reminder goes.
    @Published var paletteReadingDocument = false

    /// Bumped every time the centered palette is summoned. The view watches it
    /// to clear the query and retake focus — a fresh summon is a fresh search.
    @Published var paletteNonce = 0

    /// A palette result that needs the popover's UI to carry out (anything but
    /// opening a task, which needs no window at all). Set as the panel closes;
    /// consumed by `MenuContentView` as the popover opens.
    @Published var pendingPaletteAction: PaletteAction?

    /// The palette panel's own detail state.
    ///
    /// Deliberately **not** `peekBrief`/`taskDetail`: that pair is the
    /// popover's overlay, keyed to `peekedSlug`, and two shells sharing one
    /// slot means whichever loads second wins. They are separate windows; they
    /// get separate state.
    @Published var paletteDetail: TaskDetail?
    @Published var paletteDetailLoading = false
    private var paletteDetailSlug: String?

    /// Load a task's (or playbook's) brief + notes for a pushed palette route.
    func loadPaletteDetail(_ slug: String, kind: PeekKind = .task) {
        guard paletteDetailSlug != slug || paletteDetail == nil else { return }
        paletteDetailSlug = slug
        paletteDetail = nil
        paletteDetailLoading = true
        Task {
            let d = try? await Task.detached(priority: .userInitiated) {
                let client = FlowClient()
                return kind == .playbook ? try client.playbookDetail(slug)
                                         : try client.taskDetail(slug)
            }.value
            // Ignore a response for a route the user has already left.
            guard self.paletteDetailSlug == slug else { return }
            self.paletteDetail = d
            self.paletteDetailLoading = false
        }
    }

    /// Pre-drill requests: set before switching sections so the destination
    /// opens on one row instead of its list. Mirrors `pendingTagDrill`, which
    /// the dashboard's top-tag tiles already use.
    @Published var pendingProjectDrill: String?
    @Published var pendingPlaybookDrill: String?
    @Published var pendingOwnerDrill: String?

    /// Rebuild the index from whatever is currently loaded.
    ///
    /// Cheap (a few hundred value types) and idempotent, so every loader calls
    /// it as it lands and the list fills in progressively rather than waiting
    /// for the slowest read. A half-filled index is a legal one: searching
    /// before playbooks arrive finds tasks, not nothing.
    ///
    /// **The blocked set is sampled here, not observed.** `SessionMonitor` is
    /// its own ObservableObject and fires on every transcript delta; binding
    /// the home list to it would reorder the rows under a cursor that is
    /// already reading them. Sampling at open (and at each load) means a
    /// session that blocks while you are looking lands on the next open, which
    /// is the behaviour you want anyway.
    func rebuildPalette() {
        invalidatePaletteSearch()
        palette = PaletteIndex.build(
            tasks: allTasks.isEmpty ? tasks : allTasks,
            projects: metrics?.projects ?? [],
            playbooks: playbooks,
            owners: metrics?.owners ?? [],
            tags: metrics?.tags ?? [],
            reminders: reminders,
            blocked: sessionAlertsEnabled
                ? Set(sessionMonitor.blockedRows.map(\.slug)) : [],
            jumpList: jumpList,
            unreadRelease: unreadRelease)
    }

    /// Load the two lists only the palette needs — every task (including done
    /// and archived) and the playbook definitions. Everything else it indexes
    /// is already fetched by `refresh`/`refreshMetrics` on open.
    ///
    /// Two extra subprocesses per open, concurrent with the nine already in
    /// flight, and still nothing while the popover is closed.
    func refreshPalette() {
        paletteLoading = true
        Task {
            let c = FlowClient()
            async let all = Task.detached(priority: .userInitiated) {
                (try? c.listTasks(includeDone: true, includeArchived: true)) ?? []
            }.value
            async let pbs = Task.detached(priority: .userInitiated) {
                (try? c.listPlaybooks()) ?? []
            }.value
            let (loadedTasks, loadedPlaybooks) = await (all, pbs)
            self.allTasks = loadedTasks
            // Prune against what can still be OPENED, not merely what exists: a
            // task you finished is still in the list flow returns, but its
            // number would open nothing. Skipped on an empty read so a failed
            // `flow` call can never wipe the list.
            if !loadedTasks.isEmpty {
                let openable = Set(loadedTasks.filter { $0.canOpen }.map(\.slug))
                let pruned = self.jumpList.pruned(to: openable)
                if pruned != self.jumpList { self.jumpList = pruned }
            }
            // Same list the Playbooks section uses — filling it here is a head
            // start for that view, not a second copy.
            if !loadedPlaybooks.isEmpty { self.playbooks = loadedPlaybooks }
            self.rebuildPalette()
            self.paletteLoading = false
        }
    }

    // Tasks under a drilled-into project.
    @Published var projectTasks: [FlowTask] = []
    @Published var projectTasksLoading = false

    // Playbooks + runs (Playbooks section).
    @Published var playbooks: [Playbook] = []
    @Published var runs: [PlaybookRun] = []
    @Published var playbooksLoading = false

    // The drilled-into playbook's own brief + updates/ notes. Same shape as a
    // task's detail (see `FlowClient.playbookDetail`).
    @Published var playbookDetail: TaskDetail?
    @Published var playbookDetailLoading = false
    private var playbookDetailSlug: String?

    /// Load a playbook definition's brief + update notes for the detail view.
    func loadPlaybookDetail(_ slug: String) {
        playbookDetailSlug = slug
        playbookDetail = nil
        playbookDetailLoading = true
        Task {
            let d = try? await Task.detached(priority: .userInitiated) {
                try FlowClient().playbookDetail(slug)
            }.value
            // Ignore a response for a playbook the user has already left.
            guard self.playbookDetailSlug == slug else { return }
            self.playbookDetail = d
            self.playbookDetailLoading = false
        }
    }

    /// Clear the playbook detail when the user returns to the list.
    func clearPlaybookDetail() {
        playbookDetailSlug = nil
        playbookDetail = nil
        playbookDetailLoading = false
    }

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
            self.rebuildPalette()
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

    /// Load all tasks carrying a given tag for the Tags drill-in.
    ///
    /// Done and archived tasks are included: the tag list shows a count, and a
    /// drill-in that shows fewer rows than its own count is misleading. The
    /// view separates them below the active ones.
    func loadTagTasks(_ tag: String) {
        tagTasksLoading = true
        tagTasks = []
        Task {
            let r = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(tag: tag, includeDone: true, includeArchived: true)
            }.value) ?? []
            self.tagTasks = r
            self.invalidatePaletteSearch()
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
            self.invalidatePaletteSearch()
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

    /// Load all tasks under a project for the Projects drill-in.
    ///
    /// Includes done + archived — the project row advertises a done count, so
    /// hiding those rows made the drill-in contradict its own header.
    func loadProjectTasks(_ slug: String) {
        projectTasksLoading = true
        projectTasks = []
        Task {
            let result = (try? await Task.detached(priority: .userInitiated) {
                try FlowClient().listTasks(project: slug, includeDone: true, includeArchived: true)
            }.value) ?? []
            self.projectTasks = result
            self.invalidatePaletteSearch()
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
            self.rebuildPalette()
        }
    }

    /// Switch to a task — `flow do <slug>` focuses its live tab or spawns a
    /// new one. We dismiss the popover IMMEDIATELY (so the click feels
    /// instant) and run `flow do` fire-and-forget in the background; no
    /// post-switch refresh (the next poll/open picks up any change).
    /// Whether this open should ask flow for `--dangerously-skip-permissions`.
    ///
    /// **A held ⌥ at click time, and nothing else — deliberately not a setting.**
    /// A persistent "always skip permissions" toggle is a dangerous mode whose
    /// state lives in a window you are not looking at when you click, and the
    /// thing it suppresses is the one prompt that stops a command you did not
    /// mean to run. A modifier can only ever apply to the open you are making,
    /// which is the same reason the app keeps every terminal-spawning action
    /// explicit (see "Read-mostly philosophy" in CLAUDE.md).
    ///
    /// Safe to read on every path, including keyboard Enter: `flow do` drops
    /// the flag whenever it focuses an existing tab rather than spawning, so on
    /// a live task — which is most of this list — holding ⌥ changes nothing.
    nonisolated static func skipPermissionsRequested() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// - Parameter skipPermissions: nil asks the keyboard — a held ⌥ at click
    ///   time. A menu item passes the answer explicitly instead, because by the
    ///   time its action runs the modifier that opened the menu is long gone.
    func switchTo(_ slug: String, skipPermissions: Bool? = nil) {
        // Read the modifier before dismissing, while the click that got us here
        // is still the current event.
        let skip = skipPermissions ?? Self.skipPermissionsRequested()
        Self.dismissPopover()
        spawningOps += 1
        Task {
            do {
                let res = try await Task.detached(priority: .userInitiated) {
                    try FlowClient().doTask(slug, skipPermissions: skip)
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
    func switchToAll(_ slugs: [String], skipPermissions: Bool? = nil) {
        // Snapshot BEFORE dismissing. `dismissPopover()` synchronously triggers
        // popoverDidClose -> endActiveRefresh(), which wipes `tasks` AND
        // `selectedTaskSlugs` — so reading the selection after the dismiss reads
        // an empty set. This `let` is load-bearing.
        let batch = slugs
        guard !batch.isEmpty else { return }
        // Same modifier, same moment, before the dismiss below — unless the
        // caller stated it, which a clicked control must, since by the time its
        // action runs whatever was held is long gone.
        let skip = skipPermissions ?? Self.skipPermissionsRequested()
        // One task: reuse the proven single path (its flash/error handling is
        // already exactly right, and there is nothing to aggregate). It is told
        // the answer rather than left to re-read the keyboard, or a batch of one
        // would quietly drop a stated flag.
        if batch.count == 1 { switchTo(batch[0], skipPermissions: skip); return }

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
                let outcome = await Self.doTaskOffThread(slug, skipPermissions: skip)
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
    nonisolated private static func doTaskOffThread(
        _ slug: String, skipPermissions: Bool = false
    ) async -> BatchOutcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let res = try FlowClient().doTask(slug, skipPermissions: skipPermissions)
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
