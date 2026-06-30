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

    /// Decode `flow list tasks ... --format json` into `[FlowTask]`.
    public func listTasks(status: String? = nil) throws -> [FlowTask] {
        var args = ["list", "tasks"]
        if let status { args += ["--status", status] }
        args += ["--format", "json"]

        let (data, stderr, code) = try Self.run("flow", args)
        guard code == 0 else {
            throw FlowClientError.commandFailed(
                command: "flow " + args.joined(separator: " "),
                code: code, stderr: stderr)
        }
        do {
            return try JSONDecoder().decode([FlowTask].self, from: data)
        } catch {
            throw FlowClientError.decodeFailed(
                underlying: error,
                raw: String(data: data, encoding: .utf8) ?? "")
        }
    }

    public func inProgressTasks() throws -> [FlowTask] {
        try listTasks(status: "in-progress")
    }

    /// Parse `flow-workspace activity` text into members + their tasks.
    ///
    /// Format (no JSON mode exists):
    ///   Member Name
    ///     <slug>  <status>  [<project>]
    ///     ...
    ///   <blank line between members>
    ///
    /// Throws if the workspace is unreachable so the UI can degrade gracefully.
    public func teamActivity(includeAll: Bool = false) throws -> [TeamMember] {
        var args = ["activity"]
        if includeAll { args.append("--all") }

        let (data, stderr, code) = try Self.run("flow-workspace", args)
        let text = String(data: data, encoding: .utf8) ?? ""
        // The CLI sometimes prints "Error: ..." to stdout with rc 0 on a
        // network failure — treat either signal as unreachable.
        if code != 0 || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Error") {
            let msg = code != 0 ? stderr : text
            throw FlowClientError.commandFailed(
                command: "flow-workspace " + args.joined(separator: " "),
                code: code, stderr: msg)
        }
        return Self.parseActivity(text)
    }

    static func parseActivity(_ text: String) -> [TeamMember] {
        var members: [TeamMember] = []
        var currentName: String?
        var currentTasks: [TeamActivityTask] = []

        func flush() {
            if let name = currentName {
                members.append(TeamMember(name: name, tasks: currentTasks))
            }
            currentName = nil
            currentTasks = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let isIndented = line.first == " " || line.first == "\t"
            if !isIndented {
                // New member header.
                flush()
                currentName = line.trimmingCharacters(in: .whitespaces)
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var project: String?
                var rest = trimmed
                if let open = trimmed.lastIndex(of: "["),
                   let close = trimmed.lastIndex(of: "]"), open < close {
                    project = String(trimmed[trimmed.index(after: open)..<close])
                    rest = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
                }
                let fields = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init).filter { !$0.isEmpty }
                guard let slug = fields.first else { continue }
                let status = fields.count > 1 ? fields[1] : ""
                currentTasks.append(
                    TeamActivityTask(slug: slug, status: status, project: project))
            }
        }
        flush()
        return members
    }

    // MARK: Actions

    /// Switch to a task: focuses its live tab or spawns a new one.
    /// (Phase 3 wires this to the UI; defined here so the bridge is complete.)
    @discardableResult
    public func doTask(_ slug: String) throws -> (stderr: String, code: Int32) {
        let (_, stderr, code) = try Self.run("flow", ["do", slug])
        return (stderr, code)
    }
}
