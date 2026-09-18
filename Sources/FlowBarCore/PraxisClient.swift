import Foundation

/// Thin bridge over the praxis harness CLI (`prx`).
///
/// Same contract as `FlowClient`, different CLI: reads go through
/// `prx work ... -json` and `prx schedule ... -json`, mutations through the
/// real subcommands. The work store is never read off disk directly — it is
/// lock-protected and atomically rewritten by the harness, and a GUI parsing
/// `task.md` behind its back would race those writes and couple the app to the
/// frontmatter.
///
/// What praxis does NOT have is playbooks and `flow stats`; those are reported
/// through `capabilities` so the UI hides the panes instead of showing empty
/// ones. Its `schedule` entries stand in for flow's owners: both are recurring
/// unattended agent runs.
public struct PraxisClient: Sendable, WorkBackend {
    public init() {}

    public var kind: BackendKind { .praxis }
    public var capabilities: BackendCapabilities { .praxis }

    // MARK: Environment

    /// Where prx installs itself, and so where flow-bar looks first.
    public static let defaultInstallPath = NSHomeDirectory() + "/.local/bin/prx"

    /// The binary to run: the user's explicit path, else the standard install
    /// location, else `prx` from PATH.
    ///
    /// Naming the conventional path rather than relying on PATH alone is worth
    /// the extra `stat`: a GUI app has no shell, so the PATH it searches is one
    /// the app made up (`CLI.searchPATH`), and "which prx did it pick?" becomes
    /// a question nobody can answer from outside. Falling back to the bare name
    /// still covers an install somewhere else on that list.
    ///
    /// Parameters exist for the tests; every caller uses the defaults.
    public static func binary(defaultPath: String = defaultInstallPath,
                             fileManager: FileManager = .default) -> String
    {
        let explicit = (UserDefaults.standard.string(forKey: praxisBinaryKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        if fileManager.isExecutableFile(atPath: defaultPath) { return defaultPath }
        return BackendKind.praxis.binaryName
    }

    /// The agent directory (praxis's profile root), or nil to let prx use its
    /// own default (`~/.praxis/agent`).
    static func praxisEnv() -> [String: String?] {
        guard let dir = UserDefaults.standard.string(forKey: praxisAgentDirKey),
              !dir.isEmpty
        else { return ["PRAXIS_CODING_AGENT_DIR": nil] }
        return ["PRAXIS_CODING_AGENT_DIR": (dir as NSString).expandingTildeInPath]
    }

    @discardableResult
    static func run(_ args: [String]) throws -> (stdout: Data, stderr: String, code: Int32) {
        try CLI.run(binary(), args, env: praxisEnv())
    }

    /// Run a prx subcommand expected to emit JSON, and decode it.
    private func decodeJSON<T: Decodable>(_ type: T.Type, _ args: [String]) throws -> T {
        let (data, stderr, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "prx " + args.joined(separator: " "),
                code: code, stderr: stderr.isEmpty ? Self.errorText(data) : stderr)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CLIError.decodeFailed(
                underlying: error,
                raw: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// `prx ... -json` reports a failure as `{"error": "..."}` on stdout as
    /// well as stderr, so a GUI that only captured stdout still has the reason.
    static func errorText(_ data: Data) -> String {
        struct Failure: Decodable { var error: String }
        return (try? JSONDecoder().decode(Failure.self, from: data).error) ?? ""
    }

    // MARK: Wire shapes
    //
    // Mirrors of what `prx work` emits (docs/design/WORK-CLI.md in
    // praxis-harness). `FlowTask`, `Project` and `TagCount` decode as they
    // stand: the CLI's keys are the frontmatter's names, which is what those
    // models already read.

    private struct TaskListPayload: Decodable {
        var tasks: [FlowTask]?
        var skipped: [Skip]?
    }

    private struct ProjectListPayload: Decodable {
        var projects: [Project]?
        var skipped: [Skip]?
    }

    /// An entity the store could not read. Surfaced in the log rather than
    /// dropped: a task vanishing in silence reads as a deleted task.
    private struct Skip: Decodable {
        var kind: String?
        var slug: String?
        var reason: String?
    }

    private struct NotePayload: Decodable {
        var name: String?
        var date: String?
        var title: String?
        var body: String?
    }

    private struct ShowPayload: Decodable {
        var slug: String?
        var name: String?
        var status: String?
        var archived: Bool?
        var workDir: String?
        var brief: String?
        var notes: [NotePayload]?
        var holders: [String]?
        var live: Bool?
        /// Every stretch a session spent on this task, oldest first. This is
        /// what makes "open the task" able to RESUME rather than start over.
        var segments: [SegmentPayload]?

        enum CodingKeys: String, CodingKey {
            case slug, name, status, archived, brief, notes, holders, live, segments
            case workDir = "work_dir"
        }
    }

    private struct SegmentPayload: Decodable {
        var session: String?
        var start: String?
        var end: String?
        var open: Bool?
    }

    private struct SchedulePayload: Decodable {
        var entries: [ScheduleEntry]?
    }

    private struct ScheduleEntry: Decodable {
        var id: String
        var every: String?
        var at: String?
        var enabled: Bool?
        var nextRun: String?
        var dueInSeconds: Int?
        /// The work task this schedule's runs are attributed to, if any.
        var workRef: String?

        // schedule.Entry's own tags are camelCase, and the two fields `status`
        // adds follow it — so no remapping is needed here. The `work` shapes
        // are snake_case because they mirror the store's frontmatter instead.
        enum CodingKeys: String, CodingKey {
            case id, every, at, enabled, nextRun, dueInSeconds, workRef
        }
    }

    // MARK: Reads

    /// `prx work list tasks -json`.
    ///
    /// praxis lists every status it is not asked to filter, where flow hides
    /// done tasks unless asked. The app is written to flow's rule, so an
    /// unfiltered listing drops done rows here — but only when no explicit
    /// status was requested, or `tasks(status: "done")` would return nothing.
    public func listTasks(status: String?, tag: String?, project: String?,
                          includeDone: Bool, includeArchived: Bool) throws -> [FlowTask]
    {
        var args = ["work", "list", "tasks"]
        if let status { args += ["-status", status] }
        if let tag { args += ["-tag", tag] }
        if let project { args += ["-project", project] }
        if includeArchived { args += ["-include-archived"] }
        args += ["-json"]

        let payload = try decodeJSON(TaskListPayload.self, args)
        Self.logSkips(payload.skipped, command: "work list tasks")
        let rows = payload.tasks ?? []
        guard status == nil, !includeDone else { return rows }
        return rows.filter { $0.status != "done" }
    }

    public func listProjects() throws -> [Project] {
        let payload = try decodeJSON(ProjectListPayload.self, ["work", "list", "projects", "-json"])
        Self.logSkips(payload.skipped, command: "work list projects")
        return payload.projects ?? []
    }

    /// praxis has no playbooks. The pane is hidden by `capabilities`, so this
    /// is only reached by a dashboard that asks for everything and tolerates
    /// nothing coming back.
    public func listPlaybooks() throws -> [Playbook] { [] }

    public func listRuns() throws -> [PlaybookRun] { [] }

    /// praxis schedules, as the UI's recurring-agent rows.
    public func listOwners() throws -> [Owner] {
        let payload = try decodeJSON(SchedulePayload.self, ["schedule", "status", "-json"])
        return (payload.entries ?? []).map { entry in
            Owner(slug: entry.id,
                  status: (entry.enabled ?? false) ? "active" : "paused",
                  every: Self.cadence(every: entry.every, at: entry.at),
                  nextTick: entry.nextRun,
                  nextTickRelative: entry.dueInSeconds.map(Self.relative))
        }
    }

    /// A praxis schedule names at most one work task (`-work`), so the drill-in
    /// shows that task rather than flow's tag convention, which praxis has no
    /// equivalent of.
    public func tasksFor(owner slug: String) throws -> [FlowTask] {
        let payload = try decodeJSON(SchedulePayload.self, ["schedule", "list", "-json"])
        guard let ref = (payload.entries ?? []).first(where: { $0.id == slug })?.workRef,
              !ref.isEmpty
        else { return [] }
        return try tasks(includeDone: true, includeArchived: true)
            .filter { $0.slug == ref }
    }

    public func listTags() throws -> [TagCount] {
        try decodeJSON([TagCount].self, ["work", "tags", "-json"])
    }

    /// praxis has no playbook runs, so "including runs" is the plain list.
    /// Spelled out rather than defaulted in an extension so the UI's
    /// `any WorkBackend` dispatches to it dynamically — see the protocol.
    public func inProgressTasksIncludingRuns() throws -> [FlowTask] {
        try inProgressTasks()
    }

    public func taskDetail(_ slug: String) throws -> TaskDetail {
        let payload = try show(slug)
        // `prx work show` already returns notes newest-first.
        let updates = (payload.notes ?? []).map { note in
            TaskUpdate(filename: note.name ?? "",
                       date: note.date ?? "",
                       title: note.title ?? (note.name ?? ""),
                       content: note.body ?? "")
        }
        return TaskDetail(slug: payload.slug ?? slug,
                          name: payload.name ?? slug,
                          status: payload.status ?? "",
                          archived: payload.archived ?? false,
                          brief: payload.brief ?? "",
                          updates: updates)
    }

    public func playbookDetail(_ slug: String) throws -> TaskDetail {
        throw UnsupportedByBackend(feature: "playbooks", backend: .praxis)
    }

    /// praxis keeps no equivalent of `flow stats`; the card is hidden by
    /// `capabilities.stats` and an empty value keeps the dashboard honest.
    public func flowStats() throws -> FlowStats { FlowStats() }

    public func sessionInfo(_ slug: String) throws -> SessionInfo {
        let payload = try show(slug)
        return SessionInfo(slug: slug,
                           sessionID: payload.holders?.first,
                           workDir: payload.workDir,
                           live: payload.live ?? false)
    }

    private func show(_ slug: String) throws -> ShowPayload {
        try decodeJSON(ShowPayload.self, ["work", "show", slug, "-json"])
    }

    /// Whether this prx has a `work` command at all, read off its own help.
    ///
    /// This check is NOT optional politeness. prx treats arguments it does not
    /// recognise as a PROMPT and starts an interactive session, so running
    /// `work list tasks` against a prx that predates the command does not fail
    /// — it hangs until the runner's timeout kills it. Asking `--help` first
    /// costs one fast, side-effect-free call and turns that into a sentence.
    static func supportsWork() throws -> Bool {
        let (data, _, code) = try CLI.run(binary(), ["--help"], env: praxisEnv(), timeout: 10)
        guard code == 0, let help = String(data: data, encoding: .utf8) else { return false }
        return help.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("work ")
                || line.trimmingCharacters(in: .whitespaces) == "work"
        }
    }

    /// Which prx answered, and whether it has the `work` command this app is
    /// built on. A prx that predates `prx work` fails here with that sentence
    /// rather than quietly showing an empty task list.
    public func probe() throws -> String {
        let path = try CLI.resolve(Self.binary())
        var head = path
        if let (data, _, code) = try? Self.run(["version"]), code == 0,
           let text = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let first = text.split(separator: "\n").first
        {
            head = "\(first) · \(path)"
        }

        guard try Self.supportsWork() else {
            throw CLIError.commandFailed(
                command: "prx work", code: 2,
                stderr: "this prx has no `work` command (\(path)) — update prx, or point "
                    + "flow-bar at a build that has it. Without it there is nothing to read.")
        }

        let (data, stderr, code) = try Self.run(["work", "list", "tasks", "-json"])
        guard code == 0 else {
            let reason = [stderr, Self.errorText(data)]
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? "this prx has no `work` command — update it"
            throw CLIError.commandFailed(command: "prx work list tasks -json",
                                         code: code, stderr: reason)
        }
        let tasks = (try? JSONDecoder().decode(TaskListPayload.self, from: data))?.tasks?.count ?? 0
        return "\(head) · work: \(tasks) task\(tasks == 1 ? "" : "s")"
    }

    // MARK: Writes

    @discardableResult
    public func createTask(name: String, slug: String, project: String?, workDir: String?,
                           priority: String, due: String?, tags: [String],
                           mkdir: Bool, brief: String) throws -> String
    {
        var args = ["work", "add", "task", name, "-slug", slug, "-priority", priority]
        if let project, !project.isEmpty { args += ["-project", project] }
        if let workDir, !workDir.isEmpty {
            let dir = (workDir as NSString).expandingTildeInPath
            if mkdir { try Self.makeDirectory(dir) }
            args += ["-work-dir", dir]
        }
        if let due, !due.isEmpty { args += ["-due", due] }
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { args += ["-tag", trimmed] }
        }
        let body = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { args += ["-brief", body] }

        let (_, stderr, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(command: "prx work add task \(slug)",
                                         code: code, stderr: stderr)
        }
        return slug
    }

    @discardableResult
    public func createProject(name: String, slug: String, workDir: String,
                              priority: String, mkdir: Bool, brief: String) throws -> String
    {
        let dir = (workDir as NSString).expandingTildeInPath
        if mkdir, !dir.isEmpty { try Self.makeDirectory(dir) }

        var args = ["work", "add", "project", name, "-slug", slug, "-priority", priority]
        if !dir.isEmpty { args += ["-work-dir", dir] }
        let body = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { args += ["-brief", body] }

        let (_, stderr, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(command: "prx work add project \(slug)",
                                         code: code, stderr: stderr)
        }
        return slug
    }

    /// `prx work add` records a work directory; it does not create one. flow
    /// does both behind `--mkdir`, so the app's "create it" checkbox means the
    /// same thing on both backends.
    static func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path,
                                                withIntermediateDirectories: true)
    }

    // MARK: Actions

    /// What opening this task will do, without doing it: which directory the
    /// session starts in, and which session (if any) gets reopened.
    ///
    /// Exposed because "it opened the wrong session" is otherwise only
    /// diagnosable by opening a terminal and looking at what came up
    /// (`flowbar-smoke --resume-for <slug>`).
    public func resumePlan(_ slug: String) throws -> (workDir: String?, resume: String?) {
        let payload = try show(slug)
        return (payload.workDir, Self.resumableSession(payload))
    }

    /// Open a terminal on the task: its work directory, and the session it was
    /// last worked in — reopened, not replaced.
    ///
    /// flow opens its own terminal (`flow do`); prx is the session, not a
    /// launcher, so flow-bar opens the terminal itself. It goes through
    /// `/usr/bin/open`, which is LaunchServices rather than Apple events — no
    /// Automation grant, so no silent TCC failure.
    @discardableResult
    public func doTask(_ slug: String, skipPermissions: Bool = false)
        throws -> (stderr: String, code: Int32)
    {
        let payload = try? show(slug)
        let resume = Self.resumableSession(payload)

        // Already on screen? Go there. Opening a second tab on the same session
        // is what flow's `do` avoids by focusing the existing one, and without
        // it every click stacks another tab serving the session you are already
        // looking at.
        if Self.focusExistingTab(slug: slug, session: resume) {
            CLI.log("praxis do \(slug): focused the existing tab")
            return ("already open", 0)
        }

        let script = try Self.writeLaunchScript(slug: slug, workDir: payload?.workDir,
                                                resume: resume,
                                                skipPermissions: skipPermissions)
        var args = [String]()
        if let app = Self.terminalApp() { args += ["-a", app] }
        args.append(script)
        let (_, stderr, code) = try CLI.run("/usr/bin/open", args, env: Self.praxisEnv())
        return (stderr, code)
    }

    // MARK: Focusing a tab that already exists

    /// Focus the terminal tab already serving this task, if there is one.
    ///
    /// Same mechanism flow uses: a running session is found in `ps` by the id
    /// in its argv, its controlling tty identifies the tab, and AppleScript
    /// selects it. The link exists because the launch script `exec`s prx, so
    /// the tab's own process carries `-resume <session>` or `-work <slug>`.
    ///
    /// Returns false whenever the tab cannot be identified — no match, a
    /// session with no controlling terminal (every `prx sdk` run), or a
    /// terminal that is not scriptable — and the caller opens a new tab, which
    /// is the behaviour without this.
    public static func focusExistingTab(slug: String, session: String?) -> Bool {
        guard let app = terminalApp(), let script = focusScript(app: app) else { return false }
        guard let rows = try? CLI.run("/bin/ps", ["-axo", "pid,tty,command"], timeout: 10),
              let text = String(data: rows.stdout, encoding: .utf8)
        else { return false }
        // argv first — exact, and covers every tab flow-bar opened, since its
        // launch script execs prx with the id. A session someone started by
        // hand carries nothing in argv, so fall back to the harness's own
        // ownership record, which names the pid holding the session.
        guard let tty = ttyServing(slug: slug, session: session, psOutput: text)
            ?? session.flatMap({ ttyFromOwnerRecord(sessionID: $0, psOutput: text) })
        else { return false }

        let source = script.replacingOccurrences(of: "%TTY%", with: appleScriptEscape(tty))
        guard let result = try? CLI.run("/usr/bin/osascript", ["-e", source], timeout: 15),
              let out = String(data: result.stdout, encoding: .utf8)
        else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// The controlling tty of a prx process serving this task, from `ps` output.
    ///
    /// Pure, so the row matching is testable without processes. A session id is
    /// matched first because it is exact; the slug is the fallback for a tab
    /// opened before the session existed. Rows without a controlling terminal
    /// (`??`) are skipped: those are `prx sdk` runs, which have no tab.
    public static func ttyServing(slug: String, session: String?, psOutput: String) -> String? {
        let needles = [session, "-work \(slug)"].compactMap { $0 }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return nil }

        for needle in needles {
            for line in psOutput.split(separator: "\n") {
                guard line.contains(needle) else { continue }
                // `pid tty command`: the tty is the second field.
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3 else { continue }
                let tty = String(fields[1])
                guard tty != "??", tty != "?", !tty.isEmpty else { continue }
                return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            }
        }
        return nil
    }

    /// The tty of the process the harness records as holding this session.
    ///
    /// `<agentDir>/sessions/.owner/<id>.json` carries the owning pid. Most of
    /// those are `prx sdk` runs with no controlling terminal, which is why this
    /// is the fallback and not the primary source — but an interactive session
    /// started by hand appears here and nowhere else.
    ///
    /// The pid is checked against the SAME `ps` output rather than trusted: a
    /// record outlives its process, and a recycled pid pointing at an unrelated
    /// program would otherwise focus a stranger's tab.
    public static func ttyFromOwnerRecord(sessionID: String, psOutput: String) -> String? {
        guard SessionLocator.isValidSessionID(sessionID) else { return nil }
        let record = URL(fileURLWithPath: praxisAgentDir())
            .appendingPathComponent("sessions/.owner/\(sessionID).json")
        guard let data = try? Data(contentsOf: record),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, pid > 0
        else { return nil }

        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, Int(fields[0]) == pid else { continue }
            guard line.contains("prx") else { return nil }   // pid was recycled
            let tty = String(fields[1])
            guard tty != "??", tty != "?", !tty.isEmpty else { return nil }
            return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        }
        return nil
    }

    /// The praxis agent directory the app is pointed at.
    static func praxisAgentDir() -> String {
        if let dir = UserDefaults.standard.string(forKey: praxisAgentDirKey), !dir.isEmpty {
            return (dir as NSString).expandingTildeInPath
        }
        if let env = ProcessInfo.processInfo.environment["PRAXIS_CODING_AGENT_DIR"], !env.isEmpty {
            return env
        }
        return NSHomeDirectory() + "/.praxis/agent"
    }

    /// AppleScript that selects the tab whose tty matches, or reports "miss".
    ///
    /// Only iTerm2 and Terminal expose a tty per tab; the others in the picker
    /// have no scriptable way to find the right one, so they get a new tab
    /// rather than a wrong one. iTerm nests sessions inside tabs, Terminal does
    /// not — hence two scripts rather than one with a branch.
    public static func focusScript(app: String) -> String? {
        switch app {
        case "iTerm":
            return """
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "%TTY%" then
                      select w
                      tell t to select
                      tell s to select
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
              return "miss"
            end tell
            """
        case "Terminal":
            return """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "%TTY%" then
                    set frontmost of w to true
                    set selected of t to true
                    return "ok"
                  end if
                end repeat
              end repeat
              return "miss"
            end tell
            """
        default:
            return nil
        }
    }

    public static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The session to reopen for a task: the most recent one that actually
    /// contains a conversation.
    ///
    /// Two things learned the hard way, both from real store data:
    ///
    /// A segment's `open` flag is NOT liveness. It clears only when a session
    /// ends cleanly, so every killed or abandoned session leaves one open
    /// forever. Treating open as "in use" made every segment unresumable, so
    /// each click started a blank session — which added another open segment,
    /// and the next click did it again. One task had three empty sessions
    /// (531 bytes, zero message records) stacked on top of the real one.
    ///
    /// A live session is NOT excluded either. `prx -resume` already answers
    /// that case: a startup resume refused by the live writer falls through to
    /// following it (`tui/run.go`, followOwnedStartup). Showing the session the
    /// user pointed at beats opening an empty one next to it.
    ///
    /// So the only thing that disqualifies a session is having nothing in it.
    private static func resumableSession(_ payload: ShowPayload?) -> String? {
        guard let payload else { return nil }
        let ids = (payload.segments ?? []).compactMap { segment -> String? in
            guard let id = segment.session, !id.isEmpty else { return nil }
            return id
        }
        return mostRecentResumable(segments: ids, hasConversation: hasConversation)
    }

    /// The selection itself, over plain values so it can be tested without a
    /// store. `segments` is oldest-first, as the CLI emits it.
    public static func mostRecentResumable(segments: [String],
                                           hasConversation: (String) -> Bool) -> String?
    {
        segments.reversed().first(where: hasConversation)
    }

    /// Whether a praxis session transcript holds any conversation at all.
    ///
    /// A session that was opened and never used still has a header line, so
    /// "the file exists" cannot answer this — the empty ones measured 531 bytes
    /// with zero message records against 508KB and 152 for the real one. Only a
    /// bounded prefix is read: the first message record sits immediately after
    /// the header, so a session with any content declares itself in the first
    /// few KB, and a 500KB transcript is never read to answer a yes/no.
    public static func hasConversation(sessionID: String) -> Bool {
        guard let url = SessionLocator.praxisTranscriptURL(sessionID: sessionID),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: prefix, encoding: .utf8)
        else { return false }
        return text.contains("\"type\":\"message\"")
    }

    /// The `.command` script the terminal runs: move to the task's directory,
    /// then become its session. `exec` means the terminal tab IS the session —
    /// closing it ends the session, and no stray shell outlives it.
    ///
    /// With a `resume` id the session is REOPENED, so the task continues with
    /// its history instead of starting blank. Without one, a new session starts
    /// already bound to the task (`-work`), so whatever it writes is attributed.
    public static func writeLaunchScript(slug: String, workDir: String?,
                                         resume: String? = nil,
                                         skipPermissions: Bool = false) throws -> String
    {
        let prx = try CLI.resolve(binary())
        let dir = workDir.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var lines = ["#!/bin/sh", "cd \(shellQuote(dir)) || exit 1"]
        if let agentDir = praxisEnv()["PRAXIS_CODING_AGENT_DIR"] ?? nil {
            lines.append("export PRAXIS_CODING_AGENT_DIR=\(shellQuote(agentDir))")
        }
        // praxis spells "don't stop to ask" as a permission MODE, validated
        // against ask|auto|yolo (praxis/options.go) rather than a bare flag.
        let mode = skipPermissions ? " -permission-mode yolo" : ""
        if let resume, !resume.isEmpty {
            lines.append("exec \(shellQuote(prx)) -resume \(shellQuote(resume))\(mode)")
        } else {
            lines.append("exec \(shellQuote(prx)) -work \(shellQuote(slug))\(mode)")
        }

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("flow-bar-prx-\(slug)-\(ProcessInfo.processInfo.globallyUniqueString).command")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Single-quote a value for `/bin/sh`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The macOS application for the user's terminal pick. zellij and kitty are
    /// not app names to `open`, so they fall through to the system's default
    /// handler for a `.command` file.
    public static func terminalApp() -> String? {
        switch UserDefaults.standard.string(forKey: flowTermKey) {
        case "iterm": return "iTerm"
        case "terminal": return "Terminal"
        case "warp": return "Warp"
        case "ghostty": return "Ghostty"
        default: return nil
        }
    }

    @discardableResult
    public func runPlaybook(_ slug: String, auto: Bool) throws -> (stderr: String, code: Int32) {
        throw UnsupportedByBackend(feature: "playbooks", backend: .praxis)
    }

    /// Fire a schedule now. A praxis run is always a detached session, so there
    /// is no foreground variant to offer — `auto` is accepted for the protocol
    /// and deliberately ignored (`capabilities.recurringHasForegroundRun` is
    /// what the UI reads to stop offering the choice).
    @discardableResult
    public func ownerTick(_ slug: String, auto: Bool) throws -> (stderr: String, code: Int32) {
        let (_, stderr, code) = try Self.run(["schedule", "run", slug])
        return (stderr, code)
    }

    @discardableResult
    public func setOwner(_ slug: String, paused: Bool) throws -> (stderr: String, code: Int32) {
        let (_, stderr, code) = try Self.run(["schedule", paused ? "disable" : "enable", slug])
        return (stderr, code)
    }

    // MARK: Formatting

    /// The bare cadence — "2h", or "day at 09:00" for a daily entry. The UI
    /// prefixes "every" (see `Owner.cadenceLabel`), so this must NOT.
    public static func cadence(every: String?, at: String?) -> String {
        if let every, !every.isEmpty { return every }
        if let at, !at.isEmpty { return "day at \(at)" }
        return ""
    }

    /// Seconds until the next run, as the UI's relative string. Past due reads
    /// as "due now" rather than a negative interval.
    public static func relative(_ seconds: Int) -> String {
        guard seconds > 0 else { return "due now" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let rest = hours % 24
            return rest == 0 ? "in \(days)d" : "in \(days)d\(rest)h"
        }
        if hours > 0 { return minutes == 0 ? "in \(hours)h" : "in \(hours)h\(minutes)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in \(seconds)s"
    }

    /// An entity the store could not read is logged, never silently dropped.
    private static func logSkips(_ skips: [Skip]?, command: String) {
        guard let skips, !skips.isEmpty else { return }
        let detail = skips.map { "\($0.kind ?? "?")/\($0.slug ?? "?"): \($0.reason ?? "unreadable")" }
            .joined(separator: "; ")
        CLI.log("prx \(command): skipped \(skips.count) — \(detail)")
    }
}
