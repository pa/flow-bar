import Darwin
import Foundation

// Private SPI: mark a posix_spawn'd child as its OWN responsible process for
// TCC. macOS otherwise attributes a child's automation (e.g. flow opening a
// terminal) back to the parent GUI app (flow-bar) — so flow-bar would need the
// Accessibility/Automation grant. Disclaiming makes `flow` responsible, so flow
// "takes care of it" exactly as when you run it in a terminal.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// Errors surfaced by the flow CLI bridge.
public enum FlowClientError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case commandFailed(command: String, code: Int32, stderr: String)
    case decodeFailed(underlying: Error, raw: String)

    public var description: String {
        switch self {
        case .binaryNotFound(let name):
            return "could not locate '\(name)' on PATH or in known install locations"
        case .commandFailed(let cmd, let code, let stderr):
            return "`\(cmd)` exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .decodeFailed(let underlying, let raw):
            return "failed to decode flow output: \(underlying)\n--- raw ---\n\(raw.prefix(500))"
        }
    }
}

/// Thin bridge over the `flow` CLI.
///
/// We treat the CLI as the API: reads via `--format json`, mutations/actions
/// via real subcommands (`flow do`). We never touch flow.db directly, so we
/// don't couple to its schema and we respect flow's invariants.
/// UserDefaults key the app writes the active profile's flow root to, and the
/// client reads on every invocation. Shared so detached calls stay correct.
public let activeFlowRootKey = "activeFlowRoot"

/// UserDefaults key for the preferred flow terminal backend (FLOW_TERM). Set
/// by the app so flow opens tabs in the user's terminal (e.g. zellij) even
/// when launched from the GUI, where $ZELLIJ/$TERM_PROGRAM aren't inherited.
public let flowTermKey = "flowTerm"

public struct FlowClient: Sendable {
    /// A generous PATH so GUI launches (which inherit a minimal environment)
    /// can still find flow, claude, git, etc.
    static let searchPATH: String = {
        let home = NSHomeDirectory()
        let dirs = [
            "\(home)/.local/bin",
            "\(home)/go/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        return dirs.joined(separator: ":")
    }()

    public init() {}

    // MARK: Binary discovery

    /// Resolve an executable by name: try each PATH dir, then give up.
    static func resolve(_ name: String) throws -> String {
        let fm = FileManager.default
        for dir in searchPATH.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw FlowClientError.binaryNotFound(name)
    }

    // MARK: Process runner

    /// Run `binary args...` and return (stdout, stderr, exitCode).
    @discardableResult
    static func run(_ binaryName: String, _ args: [String]) throws
        -> (stdout: Data, stderr: String, code: Int32)
    {
        let binaryPath = try resolve(binaryName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPATH
        // Active profile's flow root (set by the app); falls back to flow's
        // own default (~/.flow) when unset.
        if let root = UserDefaults.standard.string(forKey: activeFlowRootKey), !root.isEmpty {
            env["FLOW_ROOT"] = (root as NSString).expandingTildeInPath
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Read before waiting to avoid deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (outData, stderr, process.terminationStatus)
    }

    /// Append a line to ~/Library/Logs/flow-bar.log so we can see exactly how
    /// the app invokes flow.
    static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let path = NSHomeDirectory() + "/Library/Logs/flow-bar.log"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Launch a flow subcommand that opens a terminal (do / run / tick) with TCC
    /// responsibility DISCLAIMED, so `flow` — not flow-bar — is the responsible
    /// process for the terminal it opens. BLOCKS until the flow process exits
    /// (it exits right after opening/focusing the tab) and returns its exit
    /// code — callers run this off the main actor and use the code to drive the
    /// menubar spinner→✓ so completion isn't signalled before the tab opens.
    @discardableResult
    static func spawnDisclaimed(_ binaryName: String, _ args: [String]) throws
        -> (code: Int32, output: String)
    {
        let path = try resolve(binaryName)
        let flowTerm = UserDefaults.standard.string(forKey: flowTermKey)

        // AppleScript-driven backends (flow shells out to osascript for these)
        // need the macOS Automation grant. If we DISCLAIM TCC responsibility,
        // `flow` becomes the responsible process and a menubar agent can't
        // surface the permission prompt → silent -1743. So for those backends
        // we do NOT disclaim: flow-bar stays the responsible process, so macOS
        // shows a normal, grantable "flow-bar wants to control <app>" prompt.
        // zellij/kitty use plain subprocesses (no Apple events, no TCC), so
        // disclaim there is harmless and we keep it (flow owns its terminal).
        let appleScriptBackends: Set<String> = ["iterm", "terminal", "warp", "ghostty"]
        let disclaim = !(flowTerm.map { appleScriptBackends.contains($0) } ?? false)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if disclaim { _ = responsibility_spawnattrs_setdisclaim(&attr, 1) }

        var envDict = ProcessInfo.processInfo.environment
        envDict["PATH"] = searchPATH
        if let root = UserDefaults.standard.string(forKey: activeFlowRootKey), !root.isEmpty {
            envDict["FLOW_ROOT"] = (root as NSString).expandingTildeInPath
        } else {
            envDict.removeValue(forKey: "FLOW_ROOT")
        }
        // Tell flow which terminal backend to use (GUI launches don't inherit
        // $ZELLIJ/$TERM_PROGRAM). flow honors $FLOW_TERM as a backend override.
        if let term = flowTerm, !term.isEmpty {
            envDict["FLOW_TERM"] = term
            // flow's Detect() checks $ZELLIJ and kitty's markers BEFORE
            // $FLOW_TERM. If flow-bar was launched from inside zellij/kitty it
            // inherited those, which would shadow the user's explicit pick (the
            // whole picker would be ignored). Clear any marker that selects a
            // DIFFERENT backend than the one chosen, so the pick wins.
            if term != "zellij" { envDict.removeValue(forKey: "ZELLIJ") }
            if term != "kitty" {
                envDict.removeValue(forKey: "KITTY_WINDOW_ID")
                if envDict["TERM"] == "xterm-kitty" { envDict["TERM"] = "xterm-256color" }
            }
        }

        // Redirect the child's stdout+stderr to a temp file so we can capture
        // flow's error message (e.g. an osascript/Automation-permission failure)
        // — a bare posix_spawn would inherit our fds and the reason would be
        // lost, leaving only an opaque ⚠. This does NOT affect the TCC disclaim.
        let outPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("flow-bar-spawn-\(ProcessInfo.processInfo.globallyUniqueString).log")
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        _ = outPath.withCString { cpath in
            posix_spawn_file_actions_addopen(&fa, 1, cpath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        _ = posix_spawn_file_actions_adddup2(&fa, 1, 2)  // stderr → same file as stdout

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        guard rc == 0 else {
            log("spawnDisclaimed: \(binaryName) \(args.joined(separator: " "))  ->  posix_spawn rc=\(rc) (\(String(cString: strerror(rc))))")
            throw FlowClientError.commandFailed(
                command: "\(binaryName) \(args.joined(separator: " "))",
                code: rc, stderr: String(cString: strerror(rc)))
        }
        // Wait for the short-lived child (flow exits after opening/focusing the
        // terminal) so the caller only signals completion once the tab is up.
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1  // WIFEXITED→WEXITSTATUS, else signal
        let output = ((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(atPath: outPath)
        log("spawnDisclaimed: \(binaryName) \(args.joined(separator: " "))  ->  exit=\(code)  FLOW_TERM=\(flowTerm ?? "<unset>")  disclaim=\(disclaim)  FLOW_ROOT=\(envDict["FLOW_ROOT"] ?? "<default>")\(output.isEmpty ? "" : "\n  output: \(output)")")
        return (code, output)
    }

    // MARK: Reads

    /// Run a flow subcommand expected to emit JSON, decode into `T`.
    private func decodeJSON<T: Decodable>(
        _ type: T.Type, _ args: [String]
    ) throws -> T {
        let (data, stderr, code) = try Self.run("flow", args)
        guard code == 0 else {
            throw FlowClientError.commandFailed(
                command: "flow " + args.joined(separator: " "),
                code: code, stderr: stderr)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FlowClientError.decodeFailed(
                underlying: error,
                raw: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Decode `flow list tasks ... --format json` into `[FlowTask]`.
    public func listTasks(status: String? = nil, tag: String? = nil,
                          project: String? = nil,
                          includeArchived: Bool = false) throws -> [FlowTask] {
        var args = ["list", "tasks"]
        if let status { args += ["--status", status] }
        if let tag { args += ["--tag", tag] }
        if let project { args += ["--project", project] }
        if includeArchived { args += ["--include-archived"] }
        args += ["--format", "json"]
        return try decodeJSON([FlowTask].self, args)
    }

    public func inProgressTasks() throws -> [FlowTask] {
        try listTasks(status: "in-progress")
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
        let (data, stderr, code) = try Self.run("flow", ["owner", "list"])
        guard code == 0 else {
            throw FlowClientError.commandFailed(
                command: "flow owner list", code: code, stderr: stderr)
        }
        return Self.parseOwners(String(data: data, encoding: .utf8) ?? "")
    }

    /// Parse `flow owner list` text (pure — unit-testable).
    public static func parseOwners(_ text: String) -> [Owner] {
        var owners: [Owner] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).filter { !$0.isEmpty }
            guard let first = fields.first, first != "SLUG" else { continue }
            guard fields.count >= 3 else { continue }
            // After the iso timestamp, the rest is "(in 1h59m0s)".
            let iso = fields.count > 3 ? fields[3] : nil
            let rel = fields.count > 4
                ? fields[4...].joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                : nil
            owners.append(Owner(slug: fields[0], status: fields[1],
                                every: fields[2], nextTick: iso,
                                nextTickRelative: rel))
        }
        return owners
    }

    /// `flow list tags` — text only. Header row then `#tag  N tasks`.
    public func listTags() throws -> [TagCount] {
        let (data, stderr, code) = try Self.run("flow", ["list", "tags"])
        guard code == 0 else {
            throw FlowClientError.commandFailed(
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
            let tag = first.hasPrefix("#") ? String(first.dropFirst()) : first
            let count = Int(fields[1]) ?? 0
            tags.append(TagCount(tag: tag, count: count))
        }
        return tags
    }

    /// Assemble a task's readable detail (brief + recent updates). Uses
    /// `flow show task <slug>` for the *paths* (the CLI is the source of truth
    /// for where a task's files live), then reads those markdown files. Reads
    /// files, never flow.db.
    public func taskDetail(_ slug: String) throws -> TaskDetail {
        let (data, stderr, code) = try Self.run("flow", ["show", "task", slug])
        guard code == 0 else {
            throw FlowClientError.commandFailed(
                command: "flow show task \(slug)", code: code, stderr: stderr)
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
        let (data, stderr, code) = try Self.run("flow", ["stats"])
        guard code == 0 else {
            throw FlowClientError.commandFailed(
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

    /// Build the Dashboard metrics in one shot (all local CLI calls).
    public func dashboardMetrics() throws -> DashboardMetrics {
        let ip = try inProgressTasks()
        let backlog = (try? listTasks(status: "backlog").count) ?? 0
        let done = (try? listTasks(status: "done").count) ?? 0
        let projects = (try? listProjects()) ?? []
        let runs = (try? listRuns()) ?? []
        let owners = (try? listOwners()) ?? []
        let tags = (try? listTags()) ?? []
        let questions = (try? listTasks(tag: "question")) ?? []
        return DashboardMetrics(
            inProgress: ip, backlogCount: backlog, doneCount: done,
            projects: projects, runs: runs, owners: owners, tags: tags,
            questions: questions)
    }

    // MARK: Actions

    /// Switch to a task: focuses its live tab or spawns a new one.
    /// (Phase 3 wires this to the UI; defined here so the bridge is complete.)
    @discardableResult
    public func doTask(_ slug: String) throws -> (stderr: String, code: Int32) {
        let (code, output) = try Self.spawnDisclaimed("flow", ["do", slug])  // flow owns the terminal it opens
        return (output, code)
    }

    /// Run a playbook. `auto` runs it headlessly in the background (no tab);
    /// otherwise spawns a new tab. Manual/explicit only.
    @discardableResult
    public func runPlaybook(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        if auto {  // headless, no terminal — capture normally
            let (_, stderr, code) = try Self.run("flow", ["run", "playbook", slug, "--auto"])
            return (stderr, code)
        }
        let (code, output) = try Self.spawnDisclaimed("flow", ["run", "playbook", slug])
        return (output, code)
    }

    /// Wake an owner now. `auto` ticks headlessly; otherwise spawns a tab.
    @discardableResult
    public func ownerTick(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        if auto {  // headless, no terminal — capture normally
            let (_, stderr, code) = try Self.run("flow", ["owner", "tick", slug, "--auto"])
            return (stderr, code)
        }
        let (code, output) = try Self.spawnDisclaimed("flow", ["owner", "tick", slug])
        return (output, code)
    }

    /// Pause or resume an owner — safe, no-spawn mutations.
    @discardableResult
    public func setOwner(_ slug: String, paused: Bool) throws -> (stderr: String, code: Int32) {
        let verb = paused ? "pause" : "start"
        let (_, stderr, code) = try Self.run("flow", ["owner", verb, slug])
        return (stderr, code)
    }
}
