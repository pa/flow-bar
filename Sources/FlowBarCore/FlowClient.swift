import Foundation

/// UserDefaults key the app writes the active profile's flow root to, and the
/// client reads on every invocation. Shared so detached calls stay correct.
public let activeFlowRootKey = "activeFlowRoot"

/// UserDefaults key for the preferred flow terminal backend (FLOW_TERM). Set
/// by the app so flow opens tabs in the user's terminal (e.g. zellij) even
/// when launched from the GUI, where $ZELLIJ/$TERM_PROGRAM aren't inherited.
public let flowTermKey = "flowTerm"

/// Thin bridge over the `flow` CLI.
///
/// We treat the CLI as the API: reads via `--format json`, mutations/actions
/// via real subcommands (`flow do`). We never touch flow.db directly, so we
/// don't couple to its schema and we respect flow's invariants.
///
/// Process mechanics live in `CLI`; what stays here is the part that is
/// genuinely flow's — its environment (`FLOW_ROOT`, `FLOW_TERM`), its argv, and
/// the parsers for the text its commands print.
public struct FlowClient: Sendable, WorkBackend {
    public init() {}

    public var kind: BackendKind { .flow }

    /// flow does all of it: playbooks, runs, owners and its own stats.
    public var capabilities: BackendCapabilities { .flow }

    // MARK: Environment

    /// The active profile's flow root, or nil to let flow use its own default
    /// (`~/.flow`). Read on every invocation so a profile switch takes effect
    /// without restarting the app.
    static func flowEnv() -> [String: String?] {
        guard let root = UserDefaults.standard.string(forKey: activeFlowRootKey),
              !root.isEmpty
        else { return ["FLOW_ROOT": nil] }
        return ["FLOW_ROOT": (root as NSString).expandingTildeInPath]
    }

    /// Run a flow subcommand to completion, with the profile's root applied.
    @discardableResult
    static func run(_ args: [String]) throws -> (stdout: Data, stderr: String, code: Int32) {
        try CLI.run("flow", args, env: flowEnv())
    }

    /// Launch a flow subcommand that opens a terminal (do / run / tick).
    ///
    /// flow picks its terminal backend from `$FLOW_TERM`, which a GUI launch
    /// does not inherit, so the user's pick is passed explicitly. Backends that
    /// drive AppleScript must NOT disclaim TCC responsibility: flow-bar has to
    /// stay the responsible process for macOS to show a grantable "flow-bar
    /// wants to control <app>" prompt instead of failing with a silent -1743.
    /// zellij and kitty use plain subprocesses, so disclaiming there is
    /// harmless and flow owns the terminal it opens.
    @discardableResult
    static func spawnDisclaimed(_ args: [String]) throws -> (code: Int32, output: String) {
        let flowTerm = UserDefaults.standard.string(forKey: flowTermKey)
        let appleScriptBackends: Set<String> = ["iterm", "terminal", "warp", "ghostty"]
        let disclaim = !(flowTerm.map { appleScriptBackends.contains($0) } ?? false)

        var env = flowEnv()
        if let term = flowTerm, !term.isEmpty {
            env["FLOW_TERM"] = term
            // flow's Detect() checks $ZELLIJ and kitty's markers BEFORE
            // $FLOW_TERM. If flow-bar was launched from inside zellij/kitty it
            // inherited those, which would shadow the user's explicit pick (the
            // whole picker would be ignored). Clear any marker that selects a
            // DIFFERENT backend than the one chosen, so the pick wins.
            if term != "zellij" { env["ZELLIJ"] = .some(nil) }
            if term != "kitty" {
                env["KITTY_WINDOW_ID"] = .some(nil)
                if ProcessInfo.processInfo.environment["TERM"] == "xterm-kitty" {
                    env["TERM"] = "xterm-256color"
                }
            }
        }
        return try CLI.spawn("flow", args, env: env, disclaim: disclaim)
    }

    // MARK: Reads

    /// Run a flow subcommand expected to emit JSON, decode into `T`.
    private func decodeJSON<T: Decodable>(
        _ type: T.Type, _ args: [String]
    ) throws -> T {
        let (data, stderr, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow " + args.joined(separator: " "),
                code: code, stderr: stderr)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CLIError.decodeFailed(
                underlying: error,
                raw: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// flow's convention: a task an owner is responsible for carries the tag
    /// `owner:<slug>`.
    public func tasksFor(owner slug: String) throws -> [FlowTask] {
        try listTasks(tag: "owner:\(slug)")
    }

    /// Decode `flow list tasks ... --format json` into `[FlowTask]`.
    ///
    /// **`flow` hides done tasks unless asked.** A drill-in that reports "1
    /// done" in its header and then shows nothing is worse than not counting
    /// at all, so any view that displays a total must pass `includeDone`.
    /// `--include-archived` is separate and equally opt-in.
    public func listTasks(status: String? = nil, tag: String? = nil,
                          project: String? = nil,
                          kind: String? = nil,
                          includeDone: Bool = false,
                          includeArchived: Bool = false) throws -> [FlowTask] {
        try decodeJSON([FlowTask].self, Self.listTasksArgs(
            status: status, tag: tag, project: project, kind: kind,
            includeDone: includeDone, includeArchived: includeArchived))
    }

    /// The argv for `listTasks` — split out so the flags a drill-in asks for
    /// are unit-testable without spawning `flow`.
    public static func listTasksArgs(status: String? = nil, tag: String? = nil,
                                     project: String? = nil,
                                     kind: String? = nil,
                                     includeDone: Bool = false,
                                     includeArchived: Bool = false) -> [String] {
        var args = ["list", "tasks"]
        if let status { args += ["--status", status] }
        if let tag { args += ["--tag", tag] }
        if let project { args += ["--project", project] }
        if let kind { args += ["--kind", kind] }
        if includeDone { args += ["--include-done"] }
        if includeArchived { args += ["--include-archived"] }
        args += ["--format", "json"]
        return args
    }

    /// Protocol witness for `listTasks`. Swift does not accept a method with an
    /// extra defaulted parameter as a conformance, and `kind` is flow-only —
    /// praxis has no playbook runs to ask for.
    public func listTasks(status: String?, tag: String?, project: String?,
                          includeDone: Bool, includeArchived: Bool) throws -> [FlowTask]
    {
        try listTasks(status: status, tag: tag, project: project, kind: nil,
                      includeDone: includeDone, includeArchived: includeArchived)
    }

    public func inProgressTasks() throws -> [FlowTask] {
        try listTasks(status: "in-progress")
    }

    /// In-progress tasks *including* playbook runs.
    ///
    /// **`flow list tasks` defaults to `--kind regular`, so a playbook run is
    /// not in the list at all** — not hidden behind a flag like a done task,
    /// absent. A run has a real session that flow reports `live` and that
    /// `flow do <run-slug>` switches to, so anything watching live sessions has
    /// to ask for `--kind all` or it silently ignores every running playbook.
    ///
    /// Falls back to the plain list if `--kind` is rejected: the flag is newer
    /// than flow-bar's floor, and a monitor that goes permanently dark against
    /// an older flow is a worse failure than one that misses runs.
    public func inProgressTasksIncludingRuns() throws -> [FlowTask] {
        do {
            return try listTasks(status: "in-progress", kind: "all")
        } catch {
            return try listTasks(status: "in-progress")
        }
    }

    public func listProjects() throws -> [Project] {
        try decodeJSON([Project].self, ["list", "projects", "--format", "json"])
    }

    public func listPlaybooks() throws -> [Playbook] {
        try decodeJSON([Playbook].self, ["list", "playbooks", "--format", "json"])
    }

    public func listRuns() throws -> [PlaybookRun] {
        try decodeJSON([PlaybookRun].self, ["list", "runs", "--format", "json"])
    }

    /// `flow owner list` — text only. Header row then
    /// `slug  status  every  <iso>  (in ...)`.
    public func listOwners() throws -> [Owner] {
        let (data, stderr, code) = try Self.run(["owner", "list"])
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow owner list", code: code, stderr: stderr)
        }
        return Self.parseOwners(String(data: data, encoding: .utf8) ?? "")
    }

    /// Valid `flow owner list` status values. Used to tell a real data row from
    /// prose — see `parseOwners`.
    static let ownerStatuses: Set<String> = ["active", "paused", "retired"]

    /// Parse `flow owner list` text (pure — unit-testable).
    ///
    /// `flow owner list` has no `--format json`, and when there are no owners it
    /// prints a *help sentence*, not an empty table:
    ///
    ///     No owners. Create one with: flow add owner "<name>" --work-dir <path> …
    ///
    /// Splitting that on whitespace yields ≥3 fields, so a purely positional
    /// parser happily emits a bogus owner (slug "No", status "owners.").
    /// Rows are therefore validated STRUCTURALLY: field 2 must be a real status.
    /// That also rejects any future prose without needing to match its wording.
    public static func parseOwners(_ text: String) -> [Owner] {
        var owners: [Owner] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).filter { !$0.isEmpty }
            guard let first = fields.first, first != "SLUG" else { continue }
            guard fields.count >= 3 else { continue }
            // The structural gate: prose never has a valid status in field 2.
            guard ownerStatuses.contains(fields[1].lowercased()) else { continue }
            // The NEXT TICK column is either "<iso> (in 1h59m0s)" or a bare
            // parenthesised state like "(not started)" / "(paused)". Assuming
            // field 3 is always a timestamp yields nextTick "(not" — so branch
            // on whether the column actually starts with a timestamp.
            let rest = fields.count > 3 ? Array(fields[3...]) : []
            let iso: String?
            let rel: String?
            if let head = rest.first, !head.hasPrefix("(") {
                iso = head
                rel = rest.count > 1
                    ? rest[1...].joined(separator: " ")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    : nil
            } else {
                iso = nil
                rel = rest.isEmpty
                    ? nil
                    : rest.joined(separator: " ")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            owners.append(Owner(slug: fields[0], status: fields[1],
                                every: fields[2], nextTick: iso,
                                nextTickRelative: rel))
        }
        return owners
    }

    /// `flow list tags` — text only. Header row then `#tag  N tasks`.
    /// Tags, preferring JSON.
    ///
    /// `flow list tags` DOES support `--format json` (unlike `flow owner list`),
    /// and JSON gets the empty case right — it returns `[]` where the text mode
    /// prints the prose "(no tags in use)". Text parsing is kept as a fallback
    /// for older `flow` binaries that predate the flag.
    public func listTags() throws -> [TagCount] {
        if let (data, _, code) = try? Self.run(["list", "tags", "--format", "json"]),
           code == 0,
           let tags = try? JSONDecoder().decode([TagCount].self, from: data) {
            return tags
        }
        let (data, stderr, code) = try Self.run(["list", "tags"])
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow list tags", code: code, stderr: stderr)
        }
        return Self.parseTags(String(data: data, encoding: .utf8) ?? "")
    }

    /// Parse `flow list tags` text (pure — unit-testable).
    public static func parseTags(_ text: String) -> [TagCount] {
        var tags: [TagCount] = []
        for raw in text.split(separator: "\n") {
            let fields = String(raw).split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).filter { !$0.isEmpty }
            guard let first = fields.first, first != "TAG", fields.count >= 2 else { continue }
            // Structural gate, same reasoning as parseOwners: with no tags in
            // use `flow list tags` prints the prose "(no tags in use)", which a
            // positional parser turns into a tag named "(no" with count 0. A
            // real row always has an integer count in field 2.
            guard let count = Int(fields[1]) else { continue }
            let tag = first.hasPrefix("#") ? String(first.dropFirst()) : first
            tags.append(TagCount(tag: tag, count: count))
        }
        return tags
    }

    /// Assemble a task's readable detail (brief + recent updates). Uses
    /// `flow show task <slug>` for the *paths* (the CLI is the source of truth
    /// for where a task's files live), then reads those markdown files. Reads
    /// files, never flow.db.
    public func taskDetail(_ slug: String) throws -> TaskDetail {
        try entityDetail(entity: "task", slug: slug)
    }

    /// The same brief + `updates/` read for a **playbook definition**.
    /// `flow show playbook` prints the same `brief:` / `updates:` shape as
    /// `flow show task`, so it shares the parser and the model — a playbook's
    /// notes are not second-class to a task's.
    public func playbookDetail(_ slug: String) throws -> TaskDetail {
        try entityDetail(entity: "playbook", slug: slug)
    }

    private func entityDetail(entity: String, slug: String) throws -> TaskDetail {
        let (data, stderr, code) = try Self.run(["show", entity, slug])
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow show \(entity) \(slug)", code: code, stderr: stderr)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let paths = Self.parseShowPaths(text)

        func read(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        let brief = paths.brief.map(read) ?? ""
        // `flow show task` lists updates oldest→newest; show newest first.
        let updates: [TaskUpdate] = paths.updates.reversed().map { path in
            let file = (path as NSString).lastPathComponent
            let (date, title) = Self.splitUpdateName(file)
            return TaskUpdate(filename: file, date: date, title: title, content: read(path))
        }
        return TaskDetail(slug: slug, name: paths.name ?? slug,
                          status: paths.status ?? "", archived: paths.archived,
                          brief: brief, updates: updates)
    }

    // MARK: Create (task / project intake)

    /// Create a task via `flow add task`, then write its brief. Returns the slug.
    @discardableResult
    public func createTask(name: String, slug: String, project: String?, workDir: String?,
                           priority: String, due: String?, tags: [String],
                           mkdir: Bool, brief: String) throws -> String {
        var args = ["add", "task", name, "--slug", slug, "--priority", priority]
        if let project, !project.isEmpty { args += ["--project", project] }
        // Expand ~ ourselves — flow (Go) doesn't, so a raw "~/…" becomes "/~/…".
        if let workDir, !workDir.isEmpty {
            args += ["--work-dir", (workDir as NSString).expandingTildeInPath]
        }
        if let due, !due.isEmpty { args += ["--due", due] }
        for t in tags {
            let tt = t.trimmingCharacters(in: .whitespaces)
            if !tt.isEmpty { args += ["--tag", tt] }
        }
        if mkdir { args += ["--mkdir"] }
        let (_, err, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(command: "flow add task \(slug)", code: code, stderr: err)
        }
        writeBrief(brief, entity: "task", slug: slug)
        return slug
    }

    /// Create a project via `flow add project`, then write its brief.
    @discardableResult
    public func createProject(name: String, slug: String, workDir: String,
                              priority: String, mkdir: Bool, brief: String) throws -> String {
        let absWorkDir = (workDir as NSString).expandingTildeInPath   // flow doesn't expand ~
        var args = ["add", "project", name, "--work-dir", absWorkDir, "--slug", slug, "--priority", priority]
        if mkdir { args += ["--mkdir"] }
        let (_, err, code) = try Self.run(args)
        guard code == 0 else {
            throw CLIError.commandFailed(command: "flow add project \(slug)", code: code, stderr: err)
        }
        writeBrief(brief, entity: "project", slug: slug)
        return slug
    }

    /// Write brief markdown to the file `flow show <entity> <slug>` reports.
    private func writeBrief(_ brief: String, entity: String, slug: String) {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty,
              let (data, _, code) = try? Self.run(["show", entity, slug]), code == 0,
              let path = Self.parseShowPaths(String(data: data, encoding: .utf8) ?? "").brief
        else { return }
        try? (b + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Parse `flow show task` text for the fields we surface. Pure &
    /// unit-testable. Top-level `key: value` lines set the section; indented
    /// `- <path>` lines belong to the current section (so `updates:` items are
    /// collected but the following `kb:` items are not).
    public static func parseShowPaths(_ text: String)
        -> (name: String?, status: String?, archived: Bool, brief: String?, updates: [String])
    {
        var name: String?
        var status: String?
        var archived = false
        var brief: String?
        var updates: [String] = []
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let f = line.first, f == " " || f == "\t" {
                // Continuation (list item) — belongs to the current section.
                let t = line.trimmingCharacters(in: .whitespaces)
                if section == "updates", t.hasPrefix("- ") {
                    updates.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            section = key
            switch key {
            case "name":     name = value.isEmpty ? nil : value
            case "status":   status = value.isEmpty ? nil : value
            case "archived": archived = !value.isEmpty  // "archived: <timestamp>"
            case "brief":    brief = value.isEmpty ? nil : value
            default:         break
            }
        }
        return (name, status, archived, brief, updates)
    }

    /// Split an update filename into (date, humanised title).
    /// "2026-07-01-released-and-open-sourced.md" -> ("2026-07-01", "released and open sourced").
    public static func splitUpdateName(_ filename: String) -> (date: String, title: String) {
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        let parts = base.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        // Expect YYYY-MM-DD-rest.
        if parts.count >= 4, parts[0].count == 4, Int(parts[0]) != nil {
            let date = parts[0...2].joined(separator: "-")
            let title = parts[3].replacingOccurrences(of: "-", with: " ")
            return (date, title)
        }
        return (base, base.replacingOccurrences(of: "-", with: " "))
    }

    /// `flow stats` — text only. flow's "your AI memory did the remembering"
    /// numbers. Never fatal to the dashboard: callers wrap in `try?`.
    public func flowStats() throws -> FlowStats {
        let (data, stderr, code) = try Self.run(["stats"])
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow stats", code: code, stderr: stderr)
        }
        return Self.parseStats(String(data: data, encoding: .utf8) ?? "")
    }

    /// Parse `flow stats` text (pure — unit-testable). Tolerant: matches each
    /// labelled line by substring and pulls integers out, so wording tweaks or
    /// reordering don't break it. Returns an all-nil `FlowStats` on empty input.
    public static func parseStats(_ text: String) -> FlowStats {
        // All integer runs in a string, commas stripped ("~701,842" -> 701842).
        func ints(_ str: String) -> [Int] {
            var out: [Int] = []
            var cur = ""
            for ch in str {
                if ch.isNumber || ch == "," { cur.append(ch) }
                else if !cur.isEmpty {
                    if let n = Int(cur.replacingOccurrences(of: ",", with: "")) { out.append(n) }
                    cur = ""
                }
            }
            if !cur.isEmpty, let n = Int(cur.replacingOccurrences(of: ",", with: "")) { out.append(n) }
            return out
        }

        var s = FlowStats()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let lower = line.lowercased()
            if lower.contains("recalled your context") {
                s.contextRecalls = ints(line).first
            } else if lower.contains("instant resumes") {
                s.instantResumes = ints(line).first
            } else if lower.contains("context re-established") {
                s.tokensReEstablished = ints(line).first
            } else if lower.contains("tasks done") {
                s.tasksDone = ints(line).last
            } else if lower.contains("kb facts") {
                s.kbFacts = ints(line).last
            } else if lower.contains("weekly recalls") {
                if let colon = line.firstIndex(of: ":") {
                    let glyphs = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    s.weeklyRecalls = glyphs.isEmpty ? nil : glyphs
                }
            } else if lower.contains("·"), lower.contains("resume"), lower.contains("reference") {
                // Recall breakdown: "resume 68 · reference 53 · cross-task 187 · kb 38"
                for part in line.split(separator: "·") {
                    let p = part.lowercased()
                    let n = ints(String(part)).first
                    if p.contains("cross-task") { s.crossTask = n }
                    else if p.contains("resume") { s.resumes = n }
                    else if p.contains("reference") { s.references = n }
                    else if p.contains("kb") { s.kbRecalls = n }
                }
            }
        }
        return s
    }

    /// Which flow answered, and where its root is. `flow version` is not
    /// guaranteed across builds, so a binary that refuses it still reports as
    /// found rather than as broken.
    public func probe() throws -> String {
        let path = try CLI.resolve("flow")
        let root = Self.flowEnv()["FLOW_ROOT"] ?? nil
        let where_ = "\(path) · root: \(root ?? "default")"
        guard let (data, _, code) = try? Self.run(["version"]), code == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let first = text.split(separator: "\n").first
        else { return where_ }
        return "\(first) · \(where_)"
    }

    // MARK: Actions

    /// Switch to a task: focuses its live tab or spawns a new one.
    /// (Phase 3 wires this to the UI; defined here so the bridge is complete.)
    @discardableResult
    public func doTask(_ slug: String, skipPermissions: Bool = false)
        throws -> (stderr: String, code: Int32)
    {
        // flow owns the terminal it opens
        let (code, output) = try Self.spawnDisclaimed(
            Self.doTaskArgs(slug, skipPermissions: skipPermissions))
        return (output, code)
    }

    /// The argv for `doTask` — split out for the same reason as
    /// `listTasksArgs`: the flag is the whole behaviour, and it is worth a test
    /// that does not spawn a terminal.
    ///
    /// **`--dangerously-skip-permissions` only reaches the harness on a spawn.**
    /// When the task's session is already running, `flow do` focuses that tab
    /// and returns before it ever builds a `claude` command line, so passing the
    /// flag for a live task is a no-op rather than a mode change — which is the
    /// property that makes offering it per-click safe.
    public static func doTaskArgs(_ slug: String,
                                  skipPermissions: Bool = false) -> [String] {
        var args = ["do", slug]
        if skipPermissions { args.append("--dangerously-skip-permissions") }
        return args
    }

    /// Run a playbook. `auto` runs it headlessly in the background (no tab);
    /// otherwise spawns a new tab. Manual/explicit only.
    @discardableResult
    public func runPlaybook(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        if auto {  // headless, no terminal — capture normally
            let (_, stderr, code) = try Self.run(["run", "playbook", slug, "--auto"])
            return (stderr, code)
        }
        let (code, output) = try Self.spawnDisclaimed(["run", "playbook", slug])
        return (output, code)
    }

    /// Wake an owner now. `auto` ticks headlessly; otherwise spawns a tab.
    @discardableResult
    public func ownerTick(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        if auto {  // headless, no terminal — capture normally
            let (_, stderr, code) = try Self.run(["owner", "tick", slug, "--auto"])
            return (stderr, code)
        }
        let (code, output) = try Self.spawnDisclaimed(["owner", "tick", slug])
        return (output, code)
    }

    /// Pause or resume an owner — safe, no-spawn mutations.
    @discardableResult
    public func setOwner(_ slug: String, paused: Bool) throws -> (stderr: String, code: Int32) {
        let verb = paused ? "pause" : "start"
        let (_, stderr, code) = try Self.run(["owner", verb, slug])
        return (stderr, code)
    }

    // MARK: Session binding

    // `SessionInfo` is backend-independent and lives in `WorkBackend.swift`;
    // both harnesses report the same binding.


    /// Read a task's session binding.
    ///
    /// **`flow list tasks --format json` does not emit `session_id`** — its
    /// fields are slug/name/status/priority/project/age_days/stale/live/
    /// updated/tags. The binding is only printed by `flow show task <slug>`,
    /// as text. So resolving transcripts costs one `flow show` per live task;
    /// that is why callers only resolve tasks flow already reported as `live`,
    /// which keeps the fan-out to the handful of sessions actually running.
    public func sessionInfo(_ slug: String) throws -> SessionInfo {
        let (data, stderr, code) = try Self.run(["show", "task", slug])
        guard code == 0 else {
            throw CLIError.commandFailed(
                command: "flow show task \(slug)", code: code, stderr: stderr)
        }
        return Self.parseSessionInfo(slug: slug, text: String(data: data, encoding: .utf8) ?? "")
    }

    /// Parse the `session_id:` / `work_dir:` lines out of `flow show task`.
    ///
    /// Both values carry a trailing bracketed annotation that is status, not
    /// value — `session_id: <uuid>  [live]`, `work_dir: <path>  [known]` — so
    /// the suffix is stripped (and, for the session, kept as `live`). Separate
    /// from `parseShowPaths` rather than folded into it: that function's tuple
    /// is covered by tests and used by two callers, and widening it for an
    /// unrelated field would churn both for nothing.
    public static func parseSessionInfo(slug: String, text: String) -> SessionInfo {
        var info = SessionInfo(slug: slug)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // Only top-level `key: value` lines; indented lines are list items.
            guard let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let rest = String(line[line.index(after: colon)...])
            let (value, annotation) = splitAnnotation(rest)
            switch key {
            case "session_id":
                // flow prints `(none)` (or nothing) for an unbootstrapped task.
                if !value.isEmpty, value != "(none)" {
                    info.sessionID = value
                    info.live = (annotation == "live")
                }
            case "work_dir":
                if !value.isEmpty, value != "(none)" { info.workDir = value }
            case "auto_run":
                // `running (pid 4821)` / `completed (2026-06-11T20:08:17+05:30)`
                // / `dead`. Only the leading word is state; the parenthetical is
                // detail, and `splitAnnotation` leaves it in place because it is
                // round brackets rather than square ones.
                if let first = value.split(separator: " ").first, !first.isEmpty {
                    info.autoRun = String(first)
                }
            default:
                break
            }
        }
        return info
    }

    /// Split `"  /some/path  [known]"` into `("/some/path", "known")`.
    /// A value with no trailing `[...]` comes back with an empty annotation.
    public static func splitAnnotation(_ raw: String) -> (value: String, annotation: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "[") else {
            return (trimmed, "")
        }
        let annotation = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        let value = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        return (value, annotation.trimmingCharacters(in: .whitespaces))
    }
}
