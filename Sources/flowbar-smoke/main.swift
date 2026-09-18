import FlowBarCore
import Foundation

// Phase 1 smoke test: prove the flow -> JSON -> Codable path works end to end.
// Run with:  swift run flowbar-smoke
//
// Two self-contained checks live behind flags, because they are the parts of
// the self-upgrade that unit tests cannot reach:
//
//   --upgrade-script   print the brew self-upgrade script, so it can be piped
//                      through `sh -n`. It is built by string interpolation and
//                      only ever runs when the app is quitting, which is the
//                      worst possible time to discover a syntax error.
//   --detach-test      prove a detached child outlives this process. The whole
//                      upgrade depends on it: brew quits flow-bar partway
//                      through, and an ordinary child would die with it.

if CommandLine.arguments.contains("--upgrade-script") {
    print(BrewUpgrade.script(
        appPath: "/Applications/flow-bar.app",
        bundleID: "cloud.facets.flow-bar",
        logPath: NSHomeDirectory() + "/Library/Logs/flow-bar-upgrade.log",
        markerPath: NSHomeDirectory() + "/Library/Application Support/flow-bar/last-upgrade",
        processMatch: "flow-bar.app/Contents/MacOS/flow-bar"))
    exit(0)
}

if CommandLine.arguments.contains("--detach-test") {
    let dir = NSTemporaryDirectory() + "flowbar-detach-\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let script = dir + "/child.sh"
    let marker = dir + "/survived"
    // Sleeps past this process's own exit, then reports. If the child were tied
    // to our lifetime, the marker would never appear.
    try? """
    #!/bin/sh
    sleep 3
    printf 'survived parent exit' > \(BrewUpgrade.shellQuote(marker))
    """.write(toFile: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    let ok = CLI.spawnDetached(script, logPath: dir + "/child.log")
    print("spawned=\(ok)")
    print("marker=\(marker)")
    print("parent exiting now; check the marker in ~4s")
    exit(ok ? 0 : 1)
}

// Concurrency check: the app fires its dashboard reads at once, and a hang that
// only appears under concurrency is invisible to every sequential test we have.
// Reproduces it here, where it can be measured.
if CommandLine.arguments.contains("--concurrent-test") {
    // Mirrors what the app actually does: the dashboard refresh fires ~16 reads
    // at once against a real binary, not one cheap `echo`. `--heavy` uses the
    // configured prx so each call holds its threads for real work.
    let heavy = CommandLine.arguments.contains("--heavy")
    let n = heavy ? 16 : 6
    let bin = heavy ? PraxisClient.binary() : "/bin/echo"
    let callArgs: [String] = heavy ? ["work", "list", "tasks", "-json"] : []
    print("firing \(n) concurrent CLI.run calls against \(bin)…")
    // `--swifttask` uses Task.detached, which is what the app does. That runs on
    // the COOPERATIVE pool (capped at core count), where a blocking call is the
    // documented anti-pattern — and is the one difference left between this
    // harness and the app.
    if CommandLine.arguments.contains("--swifttask") {
        let started = Date()
        let sem = DispatchSemaphore(value: 0)
        for i in 0..<n {
            Task.detached(priority: .userInitiated) {
                let t0 = Date()
                do {
                    let (out, _, code) = try CLI.run(bin, callArgs.isEmpty ? ["call-\(i)"] : callArgs,
                                                     timeout: 20)
                    print("  call-\(i): exit=\(code) \(Int(Date().timeIntervalSince(t0) * 1000))ms  \(out.count) bytes")
                } catch {
                    print("  call-\(i): FAILED after \(Int(Date().timeIntervalSince(t0) * 1000))ms — \(error)")
                }
                sem.signal()
            }
        }
        for _ in 0..<n { sem.wait() }
        print("total \(Int(Date().timeIntervalSince(started) * 1000))ms  (Task.detached)")
        exit(0)
    }

    let started = Date()
    let group = DispatchGroup()
    for i in 0..<n {
        group.enter()
        DispatchQueue.global().async {
            let t0 = Date()
            do {
                let (out, _, code) = try CLI.run(bin, callArgs.isEmpty ? ["call-\(i)"] : callArgs,
                                                 timeout: 20)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("  call-\(i): exit=\(code) \(ms)ms  \(out.count) bytes")
            } catch {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("  call-\(i): FAILED after \(ms)ms — \(error)")
            }
            group.leave()
        }
    }
    group.wait()
    print("total \(Int(Date().timeIntervalSince(started) * 1000))ms")
    exit(0)
}

// `--resume-for <slug>` answers "what will clicking this task actually open?"
// against the real store, without opening a terminal to find out.
if let i = CommandLine.arguments.firstIndex(of: "--resume-for"),
   i + 1 < CommandLine.arguments.count
{
    let slug = CommandLine.arguments[i + 1]
    if let j = CommandLine.arguments.firstIndex(of: "--prx"), j + 1 < CommandLine.arguments.count {
        UserDefaults.standard.set(CommandLine.arguments[j + 1], forKey: praxisBinaryKey)
    }
    do {
        let plan = try PraxisClient().resumePlan(slug)
        print("task:     \(slug)")
        print("work dir: \(plan.workDir ?? "(none — falls back to home)")")
        if let resume = plan.resume {
            print("resumes:  \(resume)")
        } else {
            print("resumes:  (nothing with a conversation in it — starts a session bound to the task)")
        }
        let script = try PraxisClient.writeLaunchScript(slug: slug, workDir: plan.workDir,
                                                        resume: plan.resume)
        print("script:\n" + ((try? String(contentsOfFile: script, encoding: .utf8)) ?? ""))
        try? FileManager.default.removeItem(atPath: script)
    } catch {
        FileHandle.standardError.write(Data("resume-for failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Which CLI to exercise. Defaults to whatever the app is set to, so a bare run
// reproduces what the user sees; `--backend praxis` and `--prx <path>` are how a
// prx build gets exercised before it is the installed one.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--prx"), i + 1 < args.count {
    UserDefaults.standard.set(args[i + 1], forKey: praxisBinaryKey)
}
if let i = args.firstIndex(of: "--agent-dir"), i + 1 < args.count {
    UserDefaults.standard.set(args[i + 1], forKey: praxisAgentDirKey)
}
if let i = args.firstIndex(of: "--backend"), i + 1 < args.count {
    UserDefaults.standard.set(args[i + 1], forKey: workBackendKey)
}

let client = Backend.active()
print("Backend: \(client.kind.label)")
do {
    print("  \(try client.probe())\n")
} catch {
    FileHandle.standardError.write(Data("  UNUSABLE: \(error)\n".utf8))
    exit(1)
}

do {
    let tasks = try client.inProgressTasks()
    print("Decoded \(tasks.count) in-progress task(s):\n")
    for t in tasks.sorted(by: { ($0.priority, $0.slug) < ($1.priority, $1.slug) }) {
        var badges: [String] = []
        if t.isLive { badges.append("●live") }
        if t.isStale { badges.append("⚠stale(\(t.staleDays ?? 0)d)") }
        if t.isWaiting { badges.append("⏳waiting") }
        let proj = t.projectName.map { "(\($0))" } ?? "(floating)"
        let tags = t.tagList.isEmpty ? "" : "  " + t.tagList.map { "#\($0)" }.joined(separator: " ")
        let badgeStr = badges.isEmpty ? "" : "  " + badges.joined(separator: " ")
        print("  [\(t.priority.prefix(1).uppercased())] \(t.slug)  \(proj)\(badgeStr)\(tags)")
    }
} catch {
    FileHandle.standardError.write(Data("flowbar-smoke error: \(error)\n".utf8))
    exit(1)
}

// Session data path: flow task -> session_id -> transcript file -> activity.
//
// The unit tests cover this logic against synthetic transcripts; this proves
// the same chain against the machine's real ones, which is where the parts that
// cannot be unit-tested live — that `flow show task` still prints `session_id`
// in the shape we parse, and that a session id actually resolves to a file.
print("\nLive sessions:\n")

do {
    // Mirrors SessionMonitor.resolveOffThread: playbook runs included (they are
    // absent from the default list), headless --auto runs dropped.
    let tasks = try client.inProgressTasksIncludingRuns().filter(\.isLive)
    if tasks.isEmpty {
        print("  (no live sessions — open a task from flow-bar to exercise this)")
    }
    for t in tasks {
        let info = try client.sessionInfo(t.slug)
        guard let sessionID = info.sessionID else {
            print("  \(t.slug): live, but \(client.kind.label) reports no session id  ← unexpected")
            continue
        }
        if info.autoRunning {
            print("  \(t.slug): headless --auto run — not watched (no tab, cannot prompt)")
            continue
        }
        guard let located = SessionLocator.locate(sessionID: sessionID) else {
            print("  \(t.slug): session \(sessionID.prefix(8)) has no transcript "
                  + "under any known harness root")
            continue
        }
        let tail = TranscriptTail(url: located.url)
        tail.refresh()
        let activity = tail.activity()
        let age = activity.since.map { "  (\(RelativeAge.short($0)))" } ?? ""
        print("  \(t.slug)  →  \(activity.label)\(age)")
        print("      harness:    \(located.format.label)")
        print("      session:    \(sessionID)")
        print("      transcript: \(located.url.path)")
        // cwd comes from the transcript itself; the project directory name is
        // lossy, so a mismatch here is the interesting case, not a bug.
        if let cwd = tail.parser.cwd { print("      cwd:        \(cwd)") }
        if tail.parser.malformedLines > 0 {
            print("      ⚠ \(tail.parser.malformedLines) unparseable line(s) — tail framing may be off")
        }
    }
} catch {
    FileHandle.standardError.write(Data("flowbar-smoke session error: \(error)\n".utf8))
    exit(1)
}

// Codex locator self-check.
//
// flow can bootstrap a task under either harness (`flow do --harness codex`),
// but `flow show task` does not say which, so the harness is inferred from where the
// transcript turns up. Claude's half is exercised above whenever a session is
// live; Codex's half usually isn't, so check the layout assumption directly:
// take a real rollout file, recover its thread id from the filename, and confirm
// the walk finds it again.
print("\nCodex locator self-check:\n")

let codexRoot = SessionLocator.defaultCodexRoot
if !FileManager.default.fileExists(atPath: codexRoot.path) {
    print("  (no \(codexRoot.path) — Codex has never run here)")
} else {
    let rollouts = (FileManager.default.enumerator(
        at: codexRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
        .compactMap { $0 as? URL }
        .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }) ?? []

    if rollouts.isEmpty {
        print("  (no rollout files under \(codexRoot.path))")
    } else if let sample = rollouts.first {
        // "rollout-2026-05-19T23-44-11-<uuid>.jsonl" -> the trailing uuid.
        let stem = sample.deletingPathExtension().lastPathComponent
        let threadID = stem.split(separator: "-").suffix(5).joined(separator: "-")
        print("  \(rollouts.count) rollout file(s); probing \(threadID)")
        if let found = SessionLocator.codexTranscriptURL(sessionID: threadID),
           found.path == sample.path {
            let tail = TranscriptTail(url: found)
            tail.refresh()
            print("  ✓ located, parsed as \(tail.activity().label)")
            if let cwd = tail.parser.cwd { print("      cwd: \(cwd)") }
        } else {
            print("  ✗ NOT located — the rollout filename layout has changed")
        }
    }
}
