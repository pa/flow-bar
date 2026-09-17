import AppKit
import Combine
import FlowBarCore
import Foundation

/// Watches the harness sessions behind live flow tasks, so the menubar can say
/// when one is blocked waiting for you.
///
/// ## Why this is a watch and not a poll
///
/// flow-bar's stated virtue is "no background polling; refreshes only while
/// open" (see `Store.beginActiveRefresh`). Noticing an idle session while the
/// popover is *closed* contradicts that if it is built on a timer, so it isn't:
///
/// - **Transcript changes** arrive as kqueue vnode events
///   (`DispatchSource.makeFileSystemObjectSource`), one source per live
///   session, and each event reads only the bytes appended since the last one.
///   An idle session costs nothing at all.
/// - **Binding changes** (a task gaining or losing a session) arrive the same
///   way, from a watch on the flow root directory — that is where flow's
///   SQLite database and its WAL sidecars live, so any mutation touches it.
/// - **The one timer** is a single-shot armed only while a tool call is
///   actually outstanding, because the transition into "waiting on you" is the
///   one state change driven by elapsed time rather than by a write. kqueue
///   can report that a file changed; it can never report that eight seconds
///   passed with nothing happening. See `TranscriptParser.nextTransition`.
///
/// So the steady-state cost of watching is one file descriptor per live session
/// plus one on the flow root, and zero CPU until something writes.
@MainActor
final class SessionMonitor: ObservableObject {

    /// A flow task with a live harness session.
    struct Row: Identifiable, Equatable {
        /// The task slug — stable across refreshes, and what `flow do` takes.
        let id: String
        let slug: String
        /// The task's name. Only ever a *subtitle* now — see `subtitle`.
        let name: String
        /// The harness session id — what hook alerts are keyed by.
        let sessionID: String
        /// Project name, or nil for a floating task.
        let project: String?
        /// Which harness is running it.
        let harness: TranscriptFormat
        let activity: SessionActivity
        /// Claude Code's own words for why it stopped, when the hook told us —
        /// "Bash wants to run: npm test" beats any label we could invent.
        let alert: String?

        /// What the row says it is doing.
        var statusText: String { alert ?? activity.label }

        /// The task name, when it says something the slug doesn't. Nil for a
        /// task named after its own slug and for every playbook run, whose name
        /// is just "<playbook> run <run-slug>". See `SessionRowLabel`.
        var subtitle: String? { SessionRowLabel.secondary(slug: slug, name: name) }
    }

    /// Live sessions, most-demanding first.
    ///
    /// **Only flow-managed sessions appear.** An unmanaged Claude or Codex
    /// session is one flow-bar can neither name properly nor switch to —
    /// `flow do` needs a slug — so listing it would add rows that look broken.
    @Published private(set) var boundRows: [Row] = []
    /// How many rows are asking for the user's attention right now.
    @Published private(set) var attentionCount = 0
    /// Last resolve failure, surfaced in the panel rather than swallowed.
    @Published private(set) var errorText: String?

    /// How long a tool may be outstanding before a row reads "waiting on you".
    /// User-tunable because the right value is a matter of lived experience —
    /// it trades false alarms against noticing a prompt while you're still at
    /// the keyboard — and no default can be right for every machine.
    @Published var debounce: TimeInterval = SessionMonitor.loadDebounce() {
        didSet {
            guard debounce != oldValue else { return }
            UserDefaults.standard.set(debounce, forKey: Self.debounceKey)
            recompute()
        }
    }

    /// Trace the watcher into `~/Library/Logs/flow-bar.log`. Off unless
    /// `defaults write <bundle> sessionWatchVerbose -bool true`: this fires many
    /// times a second while a session is busy, and a log that noisy would rotate
    /// away everything else in the file.
    static let verbose = UserDefaults.standard.bool(forKey: "sessionWatchVerbose")

    static let debounceKey = "sessionAttentionDebounceSeconds"
    static let defaultDebounce: TimeInterval = 8
    /// Clamped rather than validated: a zero would badge every tool call and a
    /// huge value would badge none, and both are worse than a wrong-but-sane
    /// number if the default is ever edited by hand.
    static let debounceRange: ClosedRange<TimeInterval> = 2...60

    private static func loadDebounce() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: debounceKey)
        guard stored > 0 else { return defaultDebounce }
        return min(max(stored, debounceRange.lowerBound), debounceRange.upperBound)
    }

    /// Whether the Claude Code hook is in effect. Re-read rather than cached:
    /// another tool can rewrite settings.json, and the script can be deleted.
    @Published private(set) var hookActive = false

    private var thresholds: SessionActivity.Thresholds {
        // With the hook in effect a real prompt announces itself, so guessing
        // from the tool_use gap can only add false alarms — a slow tool that a
        // `permissions.allow` rule auto-approved raises no prompt at all.
        SessionActivity.Thresholds(debounce: debounce,
                                   inferPermissionPrompts: !hookActive)
    }

    /// Re-check the hook and redraw if it changed.
    func refreshHookState() {
        let active = SessionAlertHook.isInstalled
        guard active != hookActive else { return }
        hookActive = active
        if isRunning { recompute() }
    }

    /// Sessions stopped until you answer them. Drives the menubar icon.
    ///
    /// **Deliberately narrower than what the list shows.** An icon that is lit
    /// most of the day is not a signal, and a finished turn is the normal end
    /// of every turn — measured on this machine, 8 of 12 live sessions were
    /// sitting at one. The genuinely-idle case still reaches here when Claude
    /// Code raises `idle_prompt` through the hook; it just no longer fires on
    /// every turn boundary.
    var blockedRows: [Row] { boundRows.filter { SessionAttention.isBlocked($0.activity) } }

    // MARK: State

    /// What the last resolve found: the flow side of each live session.
    private struct BoundSession: Sendable, Equatable {
        let slug: String
        let name: String
        let project: String?
        let sessionID: String
        let transcriptPath: String
        let harness: TranscriptFormat
    }

    private struct ResolveResult: Sendable {
        var bound: [BoundSession] = []
        var error: String?
    }

    /// One kqueue watch over one file or directory.
    private final class Watch {
        let source: DispatchSourceFileSystemObject
        let tail: TranscriptTail?
        init(source: DispatchSourceFileSystemObject, tail: TranscriptTail?) {
            self.source = source
            self.tail = tail
        }
        deinit { source.cancel() }
    }

    private var bound: [BoundSession] = []
    /// Live alerts from the Claude Code hook, keyed by session id.
    ///
    /// The hook gives an exact *start* — a permission prompt leaves no trace in
    /// the JSONL until it is answered. The transcript gives the *end*: once the
    /// session writes anything dated after the alert, it has moved on. Neither
    /// source can do the job alone, and together they need no debounce.
    private var alerts: [String: SessionAlert] = [:]
    /// Watches the directory the hook drops payloads into.
    private var alertWatch: Watch?

    /// How long a hook alert may stand before it is assumed stale.
    ///
    /// Needed because **Claude Code flushes its transcript at turn boundaries,
    /// not per entry** — measured: a session mid-turn left its JSONL untouched
    /// for minutes while tool calls ran. So "the transcript moved past the
    /// alert" can lag the user answering by a whole turn, and something has to
    /// catch the case where they answered and then walked away.
    static let alertExpiry: TimeInterval = 30 * 60
    /// Keyed by transcript path.
    private var transcriptWatches: [String: Watch] = [:]
    private var rootWatch: Watch?
    private var transitionTimer: DispatchWorkItem?
    private var resolveDebounce: DispatchWorkItem?
    private var resolveInFlight = false
    private var resolveRequestedWhileInFlight = false
    private(set) var isRunning = false

    // MARK: Lifecycle

    /// Begin watching. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        hookActive = SessionAlertHook.isInstalled
        watchFlowRoot()
        watchAlerts()
        resolve()
    }

    /// Stop watching and drop every watch, tail and cached row.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        transcriptWatches.removeAll()
        rootWatch = nil
        alertWatch = nil
        alerts = [:]
        transitionTimer?.cancel(); transitionTimer = nil
        resolveDebounce?.cancel(); resolveDebounce = nil
        bound = []
        boundRows = []
        attentionCount = 0
        errorText = nil
    }

    /// Forget a session's alert because the user is now dealing with it.
    ///
    /// Called when they click through from Needs-you: they are about to land in
    /// that terminal, so the alert has served its purpose. Without this the icon
    /// would stay orange until the transcript flushed, which can be a whole turn
    /// later — long enough to read as broken.
    func dismissAlert(slug: String) {
        guard let session = bound.first(where: { $0.slug == slug }),
              alerts.removeValue(forKey: session.sessionID) != nil
        else { return }
        recompute()
    }

    /// Force an authoritative re-resolve. Called when the popover opens, so what
    /// the user is looking at is never staler than the moment they clicked — the
    /// watch keeps the menubar badge honest, and opening confirms it.
    func refreshNow() {
        guard isRunning else { return }
        refreshHookState()
        resolve()
    }

    // MARK: Watching

    /// Watch the flow root directory for binding changes.
    ///
    /// The directory, not `flow.db` itself: SQLite in WAL mode writes to
    /// `flow.db-wal` and only folds back into the main file at a checkpoint, so
    /// a watch on `flow.db` alone would miss most mutations. A vnode watch on
    /// the containing directory sees the sidecars appear and change.
    private func watchFlowRoot() {
        let root = Self.flowRoot()
        guard let watch = makeWatch(path: root, tail: nil, onChange: { [weak self] in
            // Coalesced: one `flow do` touches the DB several times in a burst,
            // and each of those would otherwise be a full re-resolve.
            self?.scheduleResolve()
        }) else { return }
        rootWatch = watch
    }

    /// Watch the directory the Claude Code hook drops notification payloads
    /// into. Each drop is a session announcing that it has stopped for a human.
    private func watchAlerts() {
        let dir = SessionAlertHook.alertsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        alertWatch = makeWatch(path: dir.path, tail: nil, onChange: { [weak self] in
            self?.ingestAlerts()
        })
        ingestAlerts()   // pick up anything dropped while we weren't running
    }

    /// Fold newly-dropped hook payloads into the live alert set and redraw.
    private func ingestAlerts() {
        let fresh = SessionAlertHook.drain()
        guard !fresh.isEmpty else { return }
        for (sessionID, alert) in fresh { alerts[sessionID] = alert }
        if Self.verbose {
            FlowClient.log("sessions: ingested \(fresh.count) alert(s) — "
                           + fresh.values.map { "\($0.kind)" }.joined(separator: ", "))
        }
        recompute()
    }

    /// The active flow root — the profile the app has selected, else `~/.flow`.
    private static func flowRoot() -> String {
        if let root = UserDefaults.standard.string(forKey: activeFlowRootKey), !root.isEmpty {
            return (root as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.flow"
    }

    /// Open a kqueue vnode watch. Returns nil if the path can't be opened.
    private func makeWatch(path: String, tail: TranscriptTail?,
                           onChange: @escaping @MainActor () -> Void) -> Watch? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            // The file was replaced or unlinked out from under us — the fd now
            // points at something that no longer has a name. Re-resolve rather
            // than keep reading a ghost.
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                self.scheduleResolve()
                return
            }
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return Watch(source: source, tail: tail)
    }

    /// Coalesce resolve requests so a burst of writes costs one re-resolve.
    private func scheduleResolve() {
        resolveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resolve() }
        resolveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Resolving

    /// Ask flow which tasks are live, find each one's transcript, and reconcile
    /// the watch set against the answer.
    private func resolve() {
        guard isRunning else { return }
        guard !resolveInFlight else {
            // Never stack `flow` invocations; remember that the world moved and
            // re-run once the current answer lands.
            resolveRequestedWhileInFlight = true
            return
        }
        resolveInFlight = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.resolveOffThread()
            }.value
            guard let self, self.isRunning else { return }
            self.apply(result)
            self.resolveInFlight = false
            if self.resolveRequestedWhileInFlight {
                self.resolveRequestedWhileInFlight = false
                self.scheduleResolve()
            }
        }
    }

    /// The blocking half of a resolve: `flow` subprocesses plus a directory
    /// scan. Runs off the main actor.
    nonisolated private static func resolveOffThread() -> ResolveResult {
        var result = ResolveResult()
        let client = FlowClient()

        let tasks: [FlowTask]
        do {
            // Playbook runs included: a run is a task with a real session that
            // `flow do <run-slug>` switches to, and `flow list tasks` leaves it
            // out unless asked. An owner's work needs no special case — the
            // tasks an owner dispatches are ordinary `kind=regular` rows tagged
            // `owner:<slug>`, so they are already here.
            tasks = try client.inProgressTasksIncludingRuns()
        } catch {
            result.error = "could not read tasks: \(error)"
            return result
        }

        // `live` is flow's to report, not ours (see CLAUDE.md) — it resolves the
        // recorded session's pid. Only live tasks are worth a `flow show`.
        //
        // `flow show task` does not name the harness, so which one is running is
        // inferred from where the transcript turns up: a Claude session id is a
        // filename under ~/.claude/projects, a Codex thread id is the suffix of
        // a rollout file under ~/.codex/sessions. The id is a UUID either way,
        // so there is no collision to worry about.
        for task in tasks where task.isLive {
            guard let info = try? client.sessionInfo(task.slug),
                  let sessionID = info.sessionID,
                  // A headless `--auto` run is live and writes a transcript, but
                  // it has no tab to focus and cannot prompt, so every state it
                  // reaches is one no human can act on. Watching it would buy
                  // exactly one thing: a "your turn" alert on a session nobody
                  // can type into. See `SessionInfo.autoRunning`.
                  !info.autoRunning,
                  let located = SessionLocator.locate(sessionID: sessionID)
            else { continue }
            result.bound.append(BoundSession(slug: task.slug, name: task.name,
                                             project: task.projectName,
                                             sessionID: sessionID,
                                             transcriptPath: located.url.path,
                                             harness: located.format))
        }
        return result
    }

    /// Reconcile watches against a fresh resolve, then recompute rows.
    private func apply(_ result: ResolveResult) {
        errorText = result.error
        bound = result.bound

        let wanted = Set(result.bound.map(\.transcriptPath))
        // Drop watches for sessions that ended. Watch removal closes the fd via
        // the source's cancel handler, so this is also what stops us holding
        // descriptors open for dead sessions.
        for path in transcriptWatches.keys where !wanted.contains(path) {
            transcriptWatches.removeValue(forKey: path)
        }
        for path in wanted where transcriptWatches[path] == nil {
            let tail = TranscriptTail(url: URL(fileURLWithPath: path))
            tail.refresh()   // prime from the tail of the existing file
            guard let watch = makeWatch(path: path, tail: tail, onChange: { [weak self] in
                guard let self, let t = self.transcriptWatches[path]?.tail else { return }
                if t.refresh() { self.recompute() }
            }) else { continue }
            transcriptWatches[path] = watch
        }
        recompute()
    }

    // MARK: Rows

    /// Rebuild the published rows from the current tails and clock.
    private func recompute() {
        let now = Date()
        let th = thresholds

        var boundOut: [Row] = []
        for session in bound {
            let tail = transcriptWatches[session.transcriptPath]?.tail
            var activity = tail?.activity(now: now, thresholds: th) ?? .unknown
            var alertText: String?

            // The hook's word overrides the transcript's guess — but only while
            // the transcript agrees the session hasn't moved. A prompt answered
            // a second ago produces a `tool_result` dated after the alert, and
            // that is what retires it; the hook itself never says "done".
            if let alert = alerts[session.sessionID] {
                let lastActivity = tail?.parser.lastEventAt
                let expired = now.timeIntervalSince(alert.at) > Self.alertExpiry
                if !expired, lastActivity == nil || lastActivity! <= alert.at {
                    activity = .waitingOnYou(tool: alert.kind, since: alert.at)
                    alertText = alert.label
                } else {
                    alerts.removeValue(forKey: session.sessionID)
                }
            }

            boundOut.append(Row(id: session.slug,
                                slug: session.slug,
                                name: session.name,
                                sessionID: session.sessionID,
                                project: session.project,
                                harness: session.harness,
                                activity: activity,
                                alert: alertText))
        }
        // Forget alerts for sessions flow no longer reports as live, so a
        // machine left running overnight doesn't accumulate them.
        let liveIDs = Set(bound.map(\.sessionID))
        alerts = alerts.filter { liveIDs.contains($0.key) }

        // Attention first, then alphabetically so the list doesn't reshuffle on
        // every keystroke a session makes. By slug, because that is what the
        // row leads with — sorting on a string the eye never reads first is how
        // a list looks unsorted.
        boundOut.sort {
            $0.activity.rank != $1.activity.rank
                ? $0.activity.rank < $1.activity.rank
                : $0.slug.localizedCaseInsensitiveCompare($1.slug) == .orderedAscending
        }

        boundRows = boundOut
        // Icon budget: hard blocks only. See `blockedRows`.
        attentionCount = boundOut.filter { SessionAttention.isBlocked($0.activity) }.count
        if Self.verbose {
            FlowClient.log("sessions: recompute \(boundOut.map { "\($0.id):\($0.activity.label)" }) "
                           + "blocked=\(attentionCount) watches=\(transcriptWatches.count)")
        }

        armTransitionTimer(now: now, thresholds: th)
    }

    /// Arm the single-shot timer for the next time-driven transition.
    ///
    /// This is the whole timer budget of the feature: one pending work item,
    /// existing only while some session has a tool call outstanding, firing
    /// once at the moment that call crosses the debounce. With nothing
    /// outstanding, nothing is scheduled.
    private func armTransitionTimer(now: Date, thresholds: SessionActivity.Thresholds) {
        transitionTimer?.cancel()
        transitionTimer = nil

        // Only the debounce is clock-driven now: "finished but unseen" is
        // retired by the user looking, not by time passing.
        let next = transcriptWatches.values
            .compactMap { $0.tail?.nextTransition(now: now, thresholds: thresholds) }
            .min()
        guard let next else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.transitionTimer = nil
            self.recompute()
        }
        transitionTimer = work
        // A hair past the boundary, so the recompute lands on the far side of
        // the comparison rather than exactly on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + next + 0.05, execute: work)
    }

}
