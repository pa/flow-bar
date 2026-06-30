import Foundation

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

/// Thin bridge over the `flow` / `flow-workspace` CLIs.
///
/// We treat the CLI as the API: reads via `--format json`, mutations/actions
/// via real subcommands (`flow do`). We never touch flow.db directly, so we
/// don't couple to its schema and we respect flow's invariants.
/// UserDefaults key the app writes the active profile's flow root to, and the
/// client reads on every invocation. Shared so detached calls stay correct.
public let activeFlowRootKey = "activeFlowRoot"

public struct FlowClient: Sendable {
    /// A generous PATH so GUI launches (which inherit a minimal environment)
    /// can still find flow, flow-workspace, claude, git, etc.
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
                          project: String? = nil) throws -> [FlowTask] {
        var args = ["list", "tasks"]
        if let status { args += ["--status", status] }
        if let tag { args += ["--tag", tag] }
        if let project { args += ["--project", project] }
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
        let text = String(data: data, encoding: .utf8) ?? ""
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
        let text = String(data: data, encoding: .utf8) ?? ""
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
        let (_, stderr, code) = try Self.run("flow", ["do", slug])
        return (stderr, code)
    }

    /// Run a playbook. `auto` runs it headlessly in the background (no tab);
    /// otherwise spawns a new tab. Manual/explicit only.
    @discardableResult
    public func runPlaybook(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        var args = ["run", "playbook", slug]
        if auto { args.append("--auto") }
        let (_, stderr, code) = try Self.run("flow", args)
        return (stderr, code)
    }

    /// Wake an owner now. `auto` ticks headlessly; otherwise spawns a tab.
    @discardableResult
    public func ownerTick(_ slug: String, auto: Bool = false) throws
        -> (stderr: String, code: Int32)
    {
        var args = ["owner", "tick", slug]
        if auto { args.append("--auto") }
        let (_, stderr, code) = try Self.run("flow", args)
        return (stderr, code)
    }

    /// Pause or resume an owner — safe, no-spawn mutations.
    @discardableResult
    public func setOwner(_ slug: String, paused: Bool) throws -> (stderr: String, code: Int32) {
        let verb = paused ? "pause" : "start"
        let (_, stderr, code) = try Self.run("flow", ["owner", verb, slug])
        return (stderr, code)
    }
}
