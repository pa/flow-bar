import Darwin
import Foundation

// Private SPI: mark a posix_spawn'd child as its OWN responsible process for
// TCC. macOS otherwise attributes a child's automation (e.g. a CLI opening a
// terminal) back to the parent GUI app (flow-bar) — so flow-bar would need the
// Accessibility/Automation grant. Disclaiming makes the child responsible, so it
// "takes care of it" exactly as when you run it in a terminal.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// Errors surfaced by a CLI bridge (flow or prx).
public enum CLIError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case commandFailed(command: String, code: Int32, stderr: String)
    case decodeFailed(underlying: Error, raw: String)
    case timedOut(command: String, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .binaryNotFound(let name):
            return "could not locate '\(name)' on PATH or in known install locations"
        case .commandFailed(let cmd, let code, let stderr):
            return "`\(cmd)` exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .decodeFailed(let underlying, let raw):
            return "failed to decode CLI output: \(underlying)\n--- raw ---\n\(raw.prefix(500))"
        case .timedOut(let cmd, let seconds):
            return "`\(cmd)` did not finish within \(Int(seconds))s and was killed — "
                + "it is probably waiting for input that a menubar app cannot give it"
        }
    }
}

/// Process plumbing shared by every CLI bridge in the app: binary discovery,
/// capture-and-wait runs, disclaimed spawns, orphaned spawns, and the log.
///
/// It knows how to RUN a binary and nothing about which one. Every backend-
/// specific decision — which environment variables to set, whether a spawn
/// should disclaim TCC responsibility — is the caller's, passed in as an
/// argument. That split is what lets `flow` and `prx` share one runner instead
/// of growing a second copy of the posix_spawn dance.
public enum CLI {
    /// A generous PATH so GUI launches (which inherit a minimal environment)
    /// can still find flow, prx, claude, git, etc.
    public static let searchPATH: String = {
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

    // MARK: Binary discovery

    /// Resolve an executable: a name is looked up in each PATH dir; anything
    /// containing a `/` is taken as the path itself, which is how a user's
    /// explicit "use THIS prx" setting reaches the runner.
    public static func resolve(_ name: String) throws -> String {
        let fm = FileManager.default
        if name.contains("/") {
            let path = (name as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
            throw CLIError.binaryNotFound(name)
        }
        for dir in searchPATH.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw CLIError.binaryNotFound(name)
    }

    /// The child environment: the app's own, with `PATH` forced to
    /// `searchPATH` and `overrides` applied. A nil value REMOVES the variable
    /// — inheriting a stale `FLOW_ROOT` or `ZELLIJ` from the app's launch
    /// environment is exactly the bug that silently ignores the user's pick.
    public static func environment(_ overrides: [String: String?]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPATH
        for (key, value) in overrides {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        return env
    }

    // MARK: Process runner

    /// How long a CLI read may take before we stop waiting for it. Generous for
    /// a local command that answers in milliseconds, and short enough that a
    /// wedged one does not hold the popover's spinner for a visible age.
    public static let defaultTimeout: TimeInterval = 20

    /// Run `binary args...` to completion and return (stdout, stderr, exitCode).
    ///
    /// The call is bounded: a child that outlives `timeout` is terminated and
    /// reported as `.timedOut`. This is not paranoia — a CLI that does not
    /// recognise its arguments may decide they were a PROMPT and try to become
    /// an interactive session (prx does exactly this), and an unbounded
    /// `waitUntilExit` then hangs the app forever with nothing on screen to
    /// explain it.
    @discardableResult
    public static func run(_ binary: String, _ args: [String],
                           env overrides: [String: String?] = [:],
                           timeout: TimeInterval = CLI.defaultTimeout) throws
        -> (stdout: Data, stderr: String, code: Int32)
    {
        let binaryPath = try resolve(binary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = environment(overrides)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // /dev/null on stdin, ALWAYS. A menubar app has no terminal to answer a
        // prompt with, and a CLI that decides to be interactive — `prx` starts
        // its TUI when it does not recognise a subcommand — would otherwise read
        // from whatever we inherited and block this call forever, with the
        // popover spinning and no error to show. With /dev/null it gets EOF and
        // exits, which surfaces as an ordinary non-zero exit we can report.
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain both pipes on THIS thread with poll(2), and spawn nothing.
        //
        // Two constraints have to hold at once. Reading the pipes in sequence
        // deadlocks as soon as the child fills the other one's buffer, and a
        // task list with long briefs is well past 64KB — so both must be
        // watched together. But handing each read to its own queue costs two
        // extra threads per call, and the app issues ~16 of these at once from
        // `Task.detached`, i.e. on the Swift COOPERATIVE pool, which is capped
        // near the core count. Blocking there is already the documented
        // anti-pattern; needing 3x threads to service it starves the pool, and
        // then the reads that would release the caller can never be scheduled.
        // Measured: 16 concurrent calls via Task.detached hung indefinitely,
        // the same 16 via DispatchQueue.global() finished in 1.1s.
        //
        // poll() satisfies both: one thread, both fds, and a deadline that is
        // always bounded.
        let (outData, errData, timedOut) = drain(
            out: outPipe.fileHandleForReading.fileDescriptor,
            err: errPipe.fileHandleForReading.fileDescriptor,
            deadline: Date().addingTimeInterval(timeout))

        if timedOut {
            let command = "\(binary) \(args.joined(separator: " "))"
            log("run: \(command)  ->  TIMEOUT after \(Int(timeout))s, killing pid \(process.processIdentifier)")
            process.terminate()
            // SIGTERM, then insist. No unbounded wait anywhere on this path: a
            // call that cannot be cleaned up must still return to its caller,
            // or the thread it is on is gone for the life of the process.
            let graceUntil = Date().addingTimeInterval(2)
            while process.isRunning, Date() < graceUntil { usleep(50_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killUntil = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killUntil { usleep(50_000) }
            }
            throw CLIError.timedOut(command: command, seconds: timeout)
        }
        process.waitUntilExit()

        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (outData, stderr, process.terminationStatus)
    }

    /// Read two pipes to EOF on the calling thread, or until `deadline`.
    ///
    /// Returns what each produced and whether the deadline was hit. A closed or
    /// errored fd is retired rather than retried, so a child that closes one
    /// stream early does not spin.
    private static func drain(out outFD: Int32, err errFD: Int32,
                              deadline: Date) -> (Data, Data, Bool)
    {
        var outData = Data(), errData = Data()
        var fds = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
        var live = 2
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while live > 0 {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return (outData, errData, true) }
            let ms = Int32(min(remaining * 1000, 60_000))

            let ready = poll(&fds, nfds_t(fds.count), ms)
            if ready < 0 {
                if errno == EINTR { continue }
                break          // the fds are unusable; report what we have
            }
            if ready == 0 { return (outData, errData, true) }

            for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                let n = buffer.withUnsafeMutableBytes {
                    read(fds[i].fd, $0.baseAddress, $0.count)
                }
                if n > 0 {
                    buffer.withUnsafeBytes { raw in
                        let bytes = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        if i == 0 { outData.append(bytes, count: n) }
                        else { errData.append(bytes, count: n) }
                    }
                    continue   // more may be buffered; poll again
                }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                fds[i].fd = -1   // EOF, or an error we cannot read past
                live -= 1
            }
        }
        return (outData, errData, false)
    }

    /// Spawn a short-lived child that opens a terminal, BLOCK until it exits,
    /// and return its exit code plus whatever it printed.
    ///
    /// `disclaim` hands TCC responsibility to the child. Callers whose child
    /// drives AppleScript must pass `false`: if we disclaim, the child becomes
    /// the responsible process and a menubar agent cannot surface the
    /// Automation prompt, so the user gets a silent -1743 instead of a
    /// grantable "flow-bar wants to control <app>" dialog. Children that use
    /// plain subprocesses (no Apple events, no TCC) can disclaim safely.
    ///
    /// Output is captured through a temp file rather than a pipe: a bare
    /// posix_spawn would inherit our fds and the child's error message would be
    /// lost, leaving only an opaque failure. This does not affect the disclaim.
    @discardableResult
    public static func spawn(_ binary: String, _ args: [String],
                             env overrides: [String: String?] = [:],
                             disclaim: Bool) throws -> (code: Int32, output: String)
    {
        let path = try resolve(binary)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if disclaim { _ = responsibility_spawnattrs_setdisclaim(&attr, 1) }

        let envDict = environment(overrides)

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
            log("spawn: \(binary) \(args.joined(separator: " "))  ->  posix_spawn rc=\(rc) (\(String(cString: strerror(rc))))")
            throw CLIError.commandFailed(
                command: "\(binary) \(args.joined(separator: " "))",
                code: rc, stderr: String(cString: strerror(rc)))
        }
        // Wait for the short-lived child (it exits after opening/focusing the
        // terminal) so the caller only signals completion once the tab is up.
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1  // WIFEXITED→WEXITSTATUS, else signal
        let output = ((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(atPath: outPath)
        log("spawn: \(binary) \(args.joined(separator: " "))  ->  exit=\(code)  disclaim=\(disclaim)\(output.isEmpty ? "" : "\n  output: \(output)")")
        return (code, output)
    }

    /// Launch a script that must **outlive this app**, in its own session.
    ///
    /// Used for the Homebrew self-upgrade, where the cask's `uninstall quit:`
    /// stops flow-bar partway through: an ordinary child would be at the mercy
    /// of whatever signal tears the app down. `POSIX_SPAWN_SETSID` makes the
    /// child a session leader with no controlling terminal, so it is orphaned to
    /// launchd and keeps running rather than dying with its parent.
    ///
    /// Fire-and-forget by design — there is deliberately no `waitpid`, because
    /// the caller is about to terminate. The script reports its own outcome by
    /// writing a marker file and relaunching the app.
    @discardableResult
    public static func spawnDetached(_ path: String, _ args: [String] = [],
                                     logPath: String? = nil) -> Bool
    {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own session: survives the parent being quit, and can't be killed by a
        // signal sent to the app's process group.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        // Detach stdin, and send output somewhere durable — the app will not be
        // around to read a pipe.
        _ = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fa, 0, $0, O_RDONLY, 0)
        }
        if let logPath {
            _ = logPath.withCString {
                posix_spawn_file_actions_addopen(&fa, 1, $0, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            }
            _ = posix_spawn_file_actions_adddup2(&fa, 1, 2)
        }

        // Homebrew must be free to auto-update; the script relies on being able
        // to refresh the tap, and an inherited opt-out would defeat it.
        let envDict = environment(["HOMEBREW_NO_AUTO_UPDATE": nil])

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        guard rc == 0 else {
            log("spawnDetached: \(path) -> posix_spawn rc=\(rc) (\(String(cString: strerror(rc))))")
            return false
        }
        log("spawnDetached: \(path) -> pid \(pid) (own session)")
        return true
    }

    // MARK: Log

    /// Append a line to `~/Library/Logs/flow-bar.log`, rotating at 1 MB.
    ///
    /// A menubar agent has no console, so this is the only record of how and
    /// when the app invokes a CLI.
    public static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let dir = NSHomeDirectory() + "/Library/Logs"
        let path = dir + "/flow-bar.log"
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 1_000_000
        {
            let rotated = path + ".1"
            try? fm.removeItem(atPath: rotated)
            try? fm.moveItem(atPath: path, toPath: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
