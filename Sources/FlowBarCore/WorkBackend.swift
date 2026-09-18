import Foundation

/// Which CLI the app is driven by.
///
/// flow-bar was built against `flow`; the praxis harness (`prx`) keeps the same
/// concepts in its own native store — tasks, projects, briefs, dated notes,
/// tags, and standing scheduled jobs. Both are local CLIs that answer in JSON,
/// so the app talks to whichever one the user picks and renders the same views.
public enum BackendKind: String, CaseIterable, Sendable, Identifiable {
    case flow
    case praxis

    public var id: String { rawValue }

    /// What the user sees in the picker.
    public var label: String {
        switch self {
        case .flow: return "flow"
        case .praxis: return "praxis"
        }
    }

    /// The executable this backend drives.
    public var binaryName: String {
        switch self {
        case .flow: return "flow"
        case .praxis: return "prx"
        }
    }
}

/// UserDefaults key for the selected backend. Absent means `flow`, so an
/// existing install keeps behaving exactly as it did before the toggle existed.
public let workBackendKey = "workBackend"

/// UserDefaults key gating the praxis backend as a whole.
///
/// The backend is not GA: it needs a `prx` with the `work` command, it has no
/// playbooks or stats, and its "open a task" path is newer than flow's. So it
/// is OFF unless someone asks for it:
///
///     defaults write cloud.facets.flow-bar experimentalPraxisBackend -bool true
///
/// A hidden default rather than a visible switch, for the same reason
/// `sessionWatchVerbose` is one — shipping the control to everyone is the part
/// that makes a feature GA, and the picker itself stays hidden until this is
/// set. When it is off, a stored `workBackend` of "praxis" is ignored rather
/// than honoured, so turning the flag back off is a complete way out.
public let praxisBackendFlagKey = "experimentalPraxisBackend"

/// UserDefaults key for an explicit `prx` path. Empty means "find prx on PATH",
/// which is what a normal install wants; an explicit path is how someone points
/// the app at a build that is not the installed one.
public let praxisBinaryKey = "praxisBinary"

/// UserDefaults key for the praxis agent directory (`PRAXIS_CODING_AGENT_DIR`).
/// This is praxis's equivalent of a flow root: the work store, sessions and
/// schedules all hang off it, so switching it switches profiles wholesale.
public let praxisAgentDirKey = "praxisAgentDir"

/// What a backend can actually do, and what its concepts are called.
///
/// The two CLIs are not feature-identical and pretending otherwise would mean
/// empty panes with no explanation. A pane whose capability is false is hidden,
/// not shown broken.
public struct BackendCapabilities: Sendable {
    /// Playbook definitions and their runs (flow only).
    public var playbooks: Bool
    /// The CLI's own usage statistics (flow only — `flow stats`).
    public var stats: Bool
    /// Recurring unattended agents: flow's `owner`, praxis's `schedule`.
    public var recurring: Bool
    /// Section title for the recurring agents pane.
    public var recurringTitle: String
    /// Singular noun for one of them, for buttons and empty states.
    public var recurringNoun: String
    /// Whether "run it now, in the background" is a distinct action. flow's
    /// `--auto` runs headless; a praxis schedule run is always detached, so the
    /// distinction would be a lie.
    public var recurringHasForegroundRun: Bool
    /// Whether ONE task can have several sessions to choose between.
    ///
    /// flow binds a task to a single session, so "open the task" has exactly
    /// one destination and a picker would be a list of one. praxis records a
    /// segment per session that worked the task, so the task genuinely has
    /// several places to land and only the person knows which — hence the
    /// picker, gated here rather than inferred from a list that happens to
    /// hold one entry today.
    public var multipleSessionsPerTask: Bool
    /// Whether several interchangeable work roots exist to switch between.
    ///
    /// flow keeps its whole store under one `FLOW_ROOT`, so pointing at another
    /// one swaps every task, project and playbook at once — that is what a
    /// profile is. praxis has no equivalent: its agent directory is a harness
    /// profile, set once in Settings, not a work store you flip between while
    /// triaging. A picker offering one immovable choice is worse than no picker.
    public var workRoots: Bool

    public init(playbooks: Bool, stats: Bool, recurring: Bool,
                recurringTitle: String, recurringNoun: String,
                recurringHasForegroundRun: Bool, workRoots: Bool,
                multipleSessionsPerTask: Bool)
    {
        self.multipleSessionsPerTask = multipleSessionsPerTask
        self.playbooks = playbooks
        self.stats = stats
        self.recurring = recurring
        self.recurringTitle = recurringTitle
        self.recurringNoun = recurringNoun
        self.recurringHasForegroundRun = recurringHasForegroundRun
        self.workRoots = workRoots
    }

    public static let flow = BackendCapabilities(
        playbooks: true, stats: true, recurring: true,
        recurringTitle: "Owners", recurringNoun: "owner",
        recurringHasForegroundRun: true, workRoots: true,
        multipleSessionsPerTask: false)

    public static let praxis = BackendCapabilities(
        playbooks: false, stats: false, recurring: true,
        recurringTitle: "Schedules", recurringNoun: "schedule",
        recurringHasForegroundRun: false, workRoots: false,
        multipleSessionsPerTask: true)
}

/// Where opening a task should land.
///
/// A task with several sessions has three genuinely different answers, and
/// `String?` could only express two — "this session" and "whatever you would
/// pick" — leaving "start a fresh one even though others exist" to be smuggled
/// in as an empty string. A session you deliberately left behind is exactly the
/// one a heuristic would choose for you, so that case has to be sayable.
public enum TaskDestination: Equatable, Sendable {
    /// Whatever the backend would pick: the most recent session with something
    /// in it, or a new one when there is none. What a plain click sends.
    case auto
    /// This session, chosen by the person from the task's list.
    case session(String)
    /// A NEW session on the task, leaving the existing ones alone.
    case fresh

    /// The session id to reopen, if this destination names one.
    public var sessionID: String? {
        if case .session(let id) = self, !id.isEmpty { return id }
        return nil
    }
}

/// Raised when the UI asks a backend for something that backend does not have.
///
/// The panes are gated on `BackendCapabilities`, so this should be unreachable
/// from the UI; it exists so a wrong call fails with a sentence a user can read
/// instead of an empty list that looks like missing data.
public struct UnsupportedByBackend: Error, CustomStringConvertible {
    public let feature: String
    public let backend: BackendKind

    public init(feature: String, backend: BackendKind) {
        self.feature = feature
        self.backend = backend
    }

    public var description: String { "\(backend.label) has no \(feature)" }
}

/// A task's harness session binding.
public struct SessionInfo: Equatable, Sendable {
    public var slug: String
    /// The harness session id, or nil for a task no session has ever held.
    public var sessionID: String?
    public var workDir: String?
    /// Whether that session is still alive — the CLI's call, not ours.
    public var live: Bool
    /// State of a headless run on this task, if there has been one: `running`,
    /// `completed` or `dead`. Nil when the task has never been run headlessly.
    /// flow reports this for `flow do --auto`; praxis leaves it nil.
    public var autoRun: String?

    /// Whether a headless run owns this task right now.
    ///
    /// Load-bearing for anything that watches sessions: a headless run is live,
    /// has a transcript, and ends turns like any other session — but there is
    /// no tab behind it and no human it could be waiting for (`--auto` implies
    /// `--dangerously-skip-permissions`). Treating it as attention-worthy
    /// produces an alert nobody can act on, pointing at a terminal that does
    /// not exist.
    public var autoRunning: Bool { autoRun == "running" }

    public init(slug: String, sessionID: String? = nil,
                workDir: String? = nil, live: Bool = false,
                autoRun: String? = nil)
    {
        self.slug = slug
        self.sessionID = sessionID
        self.workDir = workDir
        self.live = live
        self.autoRun = autoRun
    }
}

/// The work-tracking surface the UI is written against, independent of which
/// CLI answers it.
///
/// Every method BLOCKS (they are subprocess calls) and is called from a
/// detached task, which is why the protocol — and every conformer — is
/// `Sendable`. Defaulted arguments are not expressible in a protocol
/// requirement, so the requirements take every argument and the convenience
/// spellings live in the extension below.
public protocol WorkBackend: Sendable {
    var kind: BackendKind { get }
    var capabilities: BackendCapabilities { get }

    // MARK: Reads

    func listTasks(status: String?, tag: String?, project: String?,
                   includeDone: Bool, includeArchived: Bool) throws -> [FlowTask]
    /// In-progress tasks *including* playbook runs.
    ///
    /// A REQUIREMENT rather than an extension default on purpose: the UI holds
    /// `any WorkBackend`, and an extension member would dispatch statically —
    /// silently dropping flow's `--kind all`, which is the only way a running
    /// playbook appears at all. praxis has no playbook runs, so its answer is
    /// the plain in-progress list.
    func inProgressTasksIncludingRuns() throws -> [FlowTask]
    func listProjects() throws -> [Project]
    func listPlaybooks() throws -> [Playbook]
    func listRuns() throws -> [PlaybookRun]
    func listOwners() throws -> [Owner]
    /// The tasks belonging to one recurring agent. The two backends answer this
    /// differently — flow tags a task `owner:<slug>`, a praxis schedule names a
    /// single work task — so the backend answers it rather than the UI guessing
    /// a convention that only one of them has.
    func tasksFor(owner slug: String) throws -> [FlowTask]
    func listTags() throws -> [TagCount]
    func taskDetail(_ slug: String) throws -> TaskDetail
    func playbookDetail(_ slug: String) throws -> TaskDetail
    func flowStats() throws -> FlowStats
    func dashboardMetrics() throws -> DashboardMetrics
    func sessionInfo(_ slug: String) throws -> SessionInfo

    /// One line saying whether this backend is usable right now: which binary
    /// answered, its version, and that the commands the app needs are there.
    /// Throws with the reason when it is not — an empty task list is not an
    /// acceptable way to report "your CLI is too old".
    func probe() throws -> String

    // MARK: Writes and actions

    @discardableResult
    func createTask(name: String, slug: String, project: String?, workDir: String?,
                    priority: String, due: String?, tags: [String],
                    mkdir: Bool, brief: String) throws -> String
    @discardableResult
    func createProject(name: String, slug: String, workDir: String,
                       priority: String, mkdir: Bool, brief: String) throws -> String
    /// Switch to a task: focus its live session's tab, or open a new one.
    ///
    /// `skipPermissions` opens a NEW session that does not stop to ask —
    /// `--dangerously-skip-permissions` on flow, `-permission-mode yolo` on
    /// praxis. It cannot change the mode of a session that is ALREADY running:
    /// a permission mode is fixed when its process starts, so on a live tab the
    /// flag is inert rather than a silent mode change. That is what makes
    /// offering it per-click safe, and why the menu disables it there.
    ///
    /// `destination` says WHERE to land when the task has more than one
    /// session: a specific one, a deliberately fresh one, or whichever the
    /// backend would choose.
    @discardableResult
    func doTask(_ slug: String, skipPermissions: Bool, destination: TaskDestination)
        throws -> (stderr: String, code: Int32)
    @discardableResult
    func runPlaybook(_ slug: String, auto: Bool) throws -> (stderr: String, code: Int32)
    /// Wake a recurring agent now (flow owner tick / praxis schedule run).
    @discardableResult
    func ownerTick(_ slug: String, auto: Bool) throws -> (stderr: String, code: Int32)
    /// Pause or resume a recurring agent.
    @discardableResult
    func setOwner(_ slug: String, paused: Bool) throws -> (stderr: String, code: Int32)
}

extension WorkBackend {
    /// `doTask` with permission prompts left on, landing wherever the backend
    /// would choose — the plain click.
    @discardableResult
    public func doTask(_ slug: String) throws -> (stderr: String, code: Int32) {
        try doTask(slug, skipPermissions: false, destination: .auto)
    }

    /// `doTask` with a permission mode, landing wherever the backend would.
    @discardableResult
    public func doTask(_ slug: String, skipPermissions: Bool)
        throws -> (stderr: String, code: Int32)
    {
        try doTask(slug, skipPermissions: skipPermissions, destination: .auto)
    }

    /// `listTasks` with the defaults the UI actually uses.
    ///
    /// **Done tasks are hidden unless asked for.** A drill-in that reports "1
    /// done" in its header and then shows nothing is worse than not counting at
    /// all, so any view that displays a total must pass `includeDone`.
    /// `includeArchived` is separate and equally opt-in.
    public func tasks(status: String? = nil, tag: String? = nil, project: String? = nil,
                      includeDone: Bool = false, includeArchived: Bool = false) throws -> [FlowTask]
    {
        try listTasks(status: status, tag: tag, project: project,
                      includeDone: includeDone, includeArchived: includeArchived)
    }

    public func inProgressTasks() throws -> [FlowTask] {
        try tasks(status: "in-progress")
    }

    /// Build the dashboard metrics in one shot. Each piece is optional: a
    /// backend that has no playbooks or no owners contributes nothing rather
    /// than failing the whole dashboard.
    public func dashboardMetrics() throws -> DashboardMetrics {
        let ip = try inProgressTasks()
        let backlog = (try? tasks(status: "backlog").count) ?? 0
        let done = (try? tasks(status: "done").count) ?? 0
        let projects = (try? listProjects()) ?? []
        let runs = (try? listRuns()) ?? []
        let owners = (try? listOwners()) ?? []
        let tagCounts = (try? listTags()) ?? []
        let questions = (try? tasks(tag: "question")) ?? []
        return DashboardMetrics(
            inProgress: ip, backlogCount: backlog, doneCount: done,
            projects: projects, runs: runs, owners: owners, tags: tagCounts,
            questions: questions)
    }
}

/// Which backend the app is pointed at right now.
///
/// Resolved from UserDefaults on every call rather than cached: the toggle has
/// to take effect on the next refresh, and a cached client would keep answering
/// from the old CLI until relaunch.
public enum Backend {
    /// Whether the praxis backend may be selected at all. See
    /// `praxisBackendFlagKey`.
    public static var praxisAvailable: Bool {
        UserDefaults.standard.bool(forKey: praxisBackendFlagKey)
    }

    public static var kind: BackendKind {
        // The flag wins over the selection. Anything else would leave a user
        // who tried praxis stuck on it after the flag went away.
        guard praxisAvailable else { return .flow }
        let raw = UserDefaults.standard.string(forKey: workBackendKey) ?? ""
        return BackendKind(rawValue: raw) ?? .flow
    }

    /// The backends a picker may offer.
    public static var selectable: [BackendKind] {
        praxisAvailable ? BackendKind.allCases : [.flow]
    }

    /// The client for the selected backend.
    public static func active() -> any WorkBackend {
        switch kind {
        case .flow: return FlowClient()
        case .praxis: return PraxisClient()
        }
    }
}
