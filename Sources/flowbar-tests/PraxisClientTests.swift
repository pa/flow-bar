import FlowBarCore
import Foundation

/// Tests for the praxis backend's pure logic.
///
/// In its own file because `main.swift` is the only place top-level code may
/// live; `runPraxisClientTests()` is called from there.
///
/// These cover the parts that are ours: how a schedule's cadence and countdown
/// are phrased, and the shell script that becomes a session. The WIRE side —
/// that `prx work … -json` still emits the keys `FlowTask` decodes — is
/// deliberately NOT faked here: a fixture invented from this client's own
/// assumptions can only ever confirm this client. That half is checked by
/// running `flowbar-smoke --backend praxis` against a real prx.
@MainActor
func runPraxisClientTests() {
    print("\nPraxisClient")

    T.test("cadence is bare, because the UI supplies \"every\"") {
        T.equal(PraxisClient.cadence(every: "2h", at: nil), "2h", "interval")
        T.equal(PraxisClient.cadence(every: "", at: "09:00"), "day at 09:00", "daily")
        T.equal(PraxisClient.cadence(every: nil, at: nil), "", "neither")
        // The full label the row renders, via the model that owns the wording.
        let hourly = Owner(slug: "x", status: "active",
                           every: PraxisClient.cadence(every: "2h", at: nil),
                           nextTick: nil, nextTickRelative: nil)
        T.equal(hourly.cadenceLabel, "every 2h", "interval label")
        let daily = Owner(slug: "x", status: "active",
                          every: PraxisClient.cadence(every: nil, at: "09:00"),
                          nextTick: nil, nextTickRelative: nil)
        T.equal(daily.cadenceLabel, "every day at 09:00", "daily label")
        let unknown = Owner(slug: "x", status: "paused", every: "",
                            nextTick: nil, nextTickRelative: nil)
        T.equal(unknown.cadenceLabel, "cadence unknown", "no cadence reads as unknown, not \"every \"")
    }

    T.test("countdown never renders a negative interval") {
        T.equal(PraxisClient.relative(0), "due now", "zero")
        T.equal(PraxisClient.relative(-90), "due now", "overdue")
        T.equal(PraxisClient.relative(45), "in 45s", "seconds")
        T.equal(PraxisClient.relative(90), "in 1m", "minutes")
        T.equal(PraxisClient.relative(3600), "in 1h", "exact hour")
        T.equal(PraxisClient.relative(5400), "in 1h30m", "hour and change")
        T.equal(PraxisClient.relative(86_400), "in 1d", "exact day")
        T.equal(PraxisClient.relative(180_000), "in 2d2h", "days and change")
    }

    T.test("shellQuote survives a quote in the path") {
        T.equal(PraxisClient.shellQuote("/tmp/plain"), "'/tmp/plain'", "plain")
        T.equal(PraxisClient.shellQuote("/tmp/it's here"), "'/tmp/it'\\''s here'", "embedded quote")
        // The point of the escaping: the result is ONE sh word again.
        let quoted = PraxisClient.shellQuote("/tmp/it's here")
        let script = "printf '%s' \(quoted)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        p.waitUntilExit()
        T.equal(out, "/tmp/it's here", "sh round-trips it as one word")
    }

    T.test("launch script cds, binds the task, and is executable") {
        // Any real executable stands in for prx: the script's shape is what is
        // under test, not which binary it ends up running.
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisBinaryKey)
        defaults.set("/bin/echo", forKey: praxisBinaryKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisBinaryKey) }
            else { defaults.removeObject(forKey: praxisBinaryKey) }
        }

        let dir = NSTemporaryDirectory() + "flow-bar tests/work'dir"
        let path = try PraxisClient.writeLaunchScript(slug: "my-task", workDir: dir)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let body = try String(contentsOfFile: path, encoding: .utf8)

        T.expect(body.hasPrefix("#!/bin/sh\n"), "has a shebang")
        T.expect(body.contains("cd '\(NSTemporaryDirectory())flow-bar tests/work'\\''dir' || exit 1"),
                 "cds to the quoted work dir")
        T.expect(body.contains("exec '/bin/echo' -work 'my-task'"),
                 "execs the binary bound to the task — exec, so the tab IS the session")
        T.expect(path.hasSuffix(".command"),
                 ".command, so LaunchServices hands it to a terminal")

        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        T.equal(perms?.int16Value, 0o755, "executable")
    }

    T.test("resume picks the newest session that has a conversation in it") {
        // Oldest-first, as the CLI emits it.
        let segs = ["sess-old", "sess-mid", "sess-new"]
        T.equal(PraxisClient.mostRecentResumable(segments: segs) { _ in true }, "sess-new",
                "newest wins when they all have content")

        // The regression this exists for: clicking a task opened a blank
        // session, which left another open segment behind, so the next click
        // did it again. Only the old session had anything in it.
        let empties: Set<String> = ["sess-blank-1", "sess-blank-2", "sess-blank-3"]
        let stacked = ["sess-real"] + Array(empties).sorted()
        T.equal(PraxisClient.mostRecentResumable(segments: stacked) { !empties.contains($0) },
                "sess-real",
                "empty sessions are skipped however many pile up on top")

        T.expect(PraxisClient.mostRecentResumable(segments: []) { _ in true } == nil,
                 "no history -> nothing to resume, so a fresh bound session")
        T.expect(PraxisClient.mostRecentResumable(segments: ["a", "b"]) { _ in false } == nil,
                 "all empty -> nothing worth resuming")
    }

    T.test("hasConversation reads content, not mere existence") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowbar-conv-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisAgentDirKey)
        defaults.set(root.path, forKey: praxisAgentDirKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisAgentDirKey) }
            else { defaults.removeObject(forKey: praxisAgentDirKey) }
            try? FileManager.default.removeItem(at: root)
        }

        // Shapes taken from the real store: an unused session carries only its
        // header line; a used one has message records after it.
        let header = #"{"type":"session","version":3,"id":"%@","cwd":"/tmp","title":"x"}"#
        func write(_ id: String, extra: String?) throws {
            let dir = root.appendingPathComponent("sessions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var body = header.replacingOccurrences(of: "%@", with: id) + "\n"
            if let extra { body += extra + "\n" }
            try body.write(to: dir.appendingPathComponent("session.jsonl"),
                           atomically: true, encoding: .utf8)
        }

        let empty = "01a0b00c-8c1d-75bc-9df5-02d0addd2c17"
        let used = "01a0a970-a677-7c25-aa11-35b2163b7b39"
        try write(empty, extra: nil)
        try write(used, extra: #"{"type":"message","id":"m1","message":{"role":"user"}}"#)

        T.expect(!PraxisClient.hasConversation(sessionID: empty),
                 "header only -> nothing to resume")
        T.expect(PraxisClient.hasConversation(sessionID: used),
                 "has a message record -> worth resuming")
        T.expect(!PraxisClient.hasConversation(sessionID: "01a0dead-0000-0000-0000-000000000000"),
                 "no transcript at all -> false, never a crash")
        T.expect(!PraxisClient.hasConversation(sessionID: "../../etc/passwd"),
                 "a bad id is rejected before it becomes a path")
    }

    T.test("an already-open tab is found by tty, so a task is not opened twice") {
        // Real shapes, taken from `ps -axo pid,tty,command` on this machine:
        // headless sdk runs have no controlling terminal, a tab does.
        let ps = """
          PID TTY      COMMAND
        10824 ??       /Users/me/.local/bin/prx sdk -prompt Post the Phase-1 UAT health
        25566 ??       /Users/me/.local/bin/prx sdk -permission-mode auto -max-turns 50
        39147 ttys008  /Users/me/.local/bin/prx -resume 01a0a970-a677-7c25-aa11-35b2163b7b39
        41002 ttys011  /Users/me/.local/bin/prx -work some-other-task
        """

        T.equal(PraxisClient.ttyServing(slug: "pi42",
                                        session: "01a0a970-a677-7c25-aa11-35b2163b7b39",
                                        psOutput: ps),
                "/dev/ttys008", "matched by session id, tty made absolute")
        T.equal(PraxisClient.ttyServing(slug: "some-other-task", session: nil, psOutput: ps),
                "/dev/ttys011", "a tab opened before the session existed matches on -work")
        T.expect(PraxisClient.ttyServing(slug: "never-opened", session: "01a0dead", psOutput: ps) == nil,
                 "no tab -> nil, and the caller opens one")

        // The bug this guard prevents: an sdk run has no tab, so focusing its
        // "tty" would either fail or select something unrelated.
        let sdkOnly = """
          PID TTY      COMMAND
        25566 ??       /Users/me/.local/bin/prx sdk -resume 01a0beef-0000-0000-0000-000000000000
        """
        T.expect(PraxisClient.ttyServing(slug: "x", session: "01a0beef-0000-0000-0000-000000000000",
                                         psOutput: sdkOnly) == nil,
                 "a session with no controlling terminal is never treated as a tab")
    }

    T.test("owner record finds a hand-started tab, and refuses a recycled pid") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowbar-owner-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisAgentDirKey)
        defaults.set(root.path, forKey: praxisAgentDirKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisAgentDirKey) }
            else { defaults.removeObject(forKey: praxisAgentDirKey) }
            try? FileManager.default.removeItem(at: root)
        }

        let id = "01a0afeb-bda6-7c25-aa11-35b2163b7b39"
        let dir = root.appendingPathComponent("sessions/.owner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Shape copied from a real record.
        let record = "{\"sessionId\":\"" + id + "\",\"pid\":64482,\"host\":\"mac\"}"
        try record.write(to: dir.appendingPathComponent(id + ".json"),
                         atomically: true, encoding: .utf8)

        let ps = """
          PID TTY      COMMAND
        64482 ttys000  /Users/me/.local/bin/prx
        """
        T.equal(PraxisClient.ttyFromOwnerRecord(sessionID: id, psOutput: ps), "/dev/ttys000",
                "a hand-started session carries nothing in argv but its owner record names it")

        // Same pid, now belonging to something else: the record outlived its
        // process and the pid came back around.
        let recycled = """
          PID TTY      COMMAND
        64482 ttys000  /usr/bin/vim notes.txt
        """
        T.expect(PraxisClient.ttyFromOwnerRecord(sessionID: id, psOutput: recycled) == nil,
                 "a recycled pid must not focus a stranger's tab")

        let headless = """
          PID TTY      COMMAND
        64482 ??       /Users/me/.local/bin/prx sdk -prompt x
        """
        T.expect(PraxisClient.ttyFromOwnerRecord(sessionID: id, psOutput: headless) == nil,
                 "an sdk owner has no tab to focus")
        T.expect(PraxisClient.ttyFromOwnerRecord(sessionID: "../escape", psOutput: ps) == nil,
                 "a bad id never becomes a path")
    }

    T.test("focus scripts exist only for terminals that expose a tty") {
        let iterm = PraxisClient.focusScript(app: "iTerm")
        T.expect(iterm?.contains("tty of s is \"%TTY%\"") == true,
                 "iTerm matches the session's tty")
        T.expect(iterm?.contains("return \"miss\"") == true,
                 "reports a miss rather than relying on osascript's exit code")
        let terminal = PraxisClient.focusScript(app: "Terminal")
        T.expect(terminal?.contains("tty of t is \"%TTY%\"") == true,
                 "Terminal matches the tab's tty — it has no nested sessions")
        T.expect(PraxisClient.focusScript(app: "Warp") == nil,
                 "a terminal with no scriptable tty gets a new tab, never a wrong one")
        T.equal(PraxisClient.appleScriptEscape("/dev/tty\"s0\\8"), "/dev/tty\\\"s0\\\\8",
                "quotes and backslashes cannot break out of the script string")
    }

    T.test("launch script resumes when there is a session, binds when there is not") {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisBinaryKey)
        defaults.set("/bin/echo", forKey: praxisBinaryKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisBinaryKey) }
            else { defaults.removeObject(forKey: praxisBinaryKey) }
        }

        let resumed = try PraxisClient.writeLaunchScript(slug: "my-task", workDir: "/tmp",
                                                         resume: "01a0-abcd")
        defer { try? FileManager.default.removeItem(atPath: resumed) }
        let resumedBody = try String(contentsOfFile: resumed, encoding: .utf8)
        T.expect(resumedBody.contains("exec '/bin/echo' -resume '01a0-abcd'"),
                 "reopens the session rather than starting blank")
        T.expect(!resumedBody.contains("-work"),
                 "a resumed session carries its own binding; -work would be redundant")
        T.expect(resumedBody.contains("cd '/tmp'"), "still moves to the workspace first")

        let fresh = try PraxisClient.writeLaunchScript(slug: "my-task", workDir: "/tmp",
                                                       resume: nil)
        defer { try? FileManager.default.removeItem(atPath: fresh) }
        let freshBody = try String(contentsOfFile: fresh, encoding: .utf8)
        T.expect(freshBody.contains("exec '/bin/echo' -work 'my-task'"),
                 "no history -> a new session, bound so its notes are attributed")
    }

    T.test("launch script falls back to home for a task with no work dir") {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisBinaryKey)
        defaults.set("/bin/echo", forKey: praxisBinaryKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisBinaryKey) }
            else { defaults.removeObject(forKey: praxisBinaryKey) }
        }
        for workDir in [nil, ""] as [String?] {
            let path = try PraxisClient.writeLaunchScript(slug: "floating", workDir: workDir)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let body = try String(contentsOfFile: path, encoding: .utf8)
            T.expect(body.contains("cd '\(NSHomeDirectory())'"),
                     "no work dir → home, never a cd to nothing")
        }
    }

    T.test("capabilities describe praxis honestly") {
        let caps = PraxisClient().capabilities
        T.expect(!caps.playbooks, "no playbooks")
        T.expect(!caps.stats, "no flow stats")
        T.expect(caps.recurring, "schedules stand in for owners")
        T.equal(caps.recurringTitle, "Schedules", "named as praxis names them")
        T.expect(!caps.recurringHasForegroundRun, "a praxis run is always detached")
        T.equal(PraxisClient().kind, .praxis, "kind")
        T.equal(BackendKind.praxis.binaryName, "prx", "binary")
    }

    T.test("unsupported features fail with a sentence, not an empty list") {
        do {
            _ = try PraxisClient().playbookDetail("anything")
            T.expect(false, "should have thrown")
        } catch let error as UnsupportedByBackend {
            T.equal("\(error)", "praxis has no playbooks", "message names backend and feature")
        } catch {
            T.expect(false, "wrong error: \(error)")
        }
        // The empty listings are the tolerant half of the same decision: a
        // dashboard that asks for everything gets nothing rather than an error.
        T.expect(try PraxisClient().listPlaybooks().isEmpty, "no playbooks")
        T.expect(try PraxisClient().listRuns().isEmpty, "no runs")
        T.expect(try PraxisClient().flowStats().isEmpty, "empty stats hide the card")
    }

    T.test("terminal pick maps to an app only where open -a can take one") {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: flowTermKey)
        defer {
            if let previous { defaults.set(previous, forKey: flowTermKey) }
            else { defaults.removeObject(forKey: flowTermKey) }
        }
        for (pick, app) in [("iterm", "iTerm"), ("terminal", "Terminal"),
                            ("warp", "Warp"), ("ghostty", "Ghostty")] {
            defaults.set(pick, forKey: flowTermKey)
            T.equal(PraxisClient.terminalApp(), app, "\(pick) → \(app)")
        }
        // zellij and kitty are not applications to open; the default handler
        // takes the .command instead of `open -a zellij` failing.
        for pick in ["zellij", "kitty", ""] {
            defaults.set(pick, forKey: flowTermKey)
            T.expect(PraxisClient.terminalApp() == nil, "\(pick) → system default handler")
        }
    }

    T.test("backend selection defaults to flow and round-trips") {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: workBackendKey)
        let previousFlag = defaults.object(forKey: praxisBackendFlagKey)
        defaults.set(true, forKey: praxisBackendFlagKey)
        defer {
            if let previous { defaults.set(previous, forKey: workBackendKey) }
            else { defaults.removeObject(forKey: workBackendKey) }
            if let previousFlag { defaults.set(previousFlag, forKey: praxisBackendFlagKey) }
            else { defaults.removeObject(forKey: praxisBackendFlagKey) }
        }
        defaults.removeObject(forKey: workBackendKey)
        T.equal(Backend.kind, .flow, "absent setting → flow, so an existing install is unchanged")
        defaults.set("nonsense", forKey: workBackendKey)
        T.equal(Backend.kind, .flow, "unreadable setting → flow, never a crash")
        defaults.set("praxis", forKey: workBackendKey)
        T.equal(Backend.kind, .praxis, "praxis selected")
        T.equal(Backend.active().kind, .praxis, "factory follows the setting")
    }

    T.test("prx resolves to the standard install path by default") {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: praxisBinaryKey)
        defer {
            if let previous { defaults.set(previous, forKey: praxisBinaryKey) }
            else { defaults.removeObject(forKey: praxisBinaryKey) }
        }
        defaults.removeObject(forKey: praxisBinaryKey)

        T.equal(PraxisClient.defaultInstallPath, NSHomeDirectory() + "/.local/bin/prx",
                "where prx installs itself")
        // Present: take it by name, so which binary answered is knowable from
        // outside instead of depending on the PATH the app invented.
        T.equal(PraxisClient.binary(defaultPath: "/bin/echo"), "/bin/echo",
                "an installed prx at the standard path wins")
        // Absent: fall back to the bare name, which CLI.resolve looks up on the
        // app's search PATH — an install somewhere else still works.
        T.equal(PraxisClient.binary(defaultPath: "/nope/prx"), "prx",
                "no install there falls back to a PATH lookup")

        // An explicit setting always wins, including over a perfectly good
        // install — that is the whole point of the field.
        defaults.set("/usr/bin/true", forKey: praxisBinaryKey)
        T.equal(PraxisClient.binary(defaultPath: "/bin/echo"), "/usr/bin/true",
                "an explicit path beats the default")
        defaults.set("   ", forKey: praxisBinaryKey)
        T.equal(PraxisClient.binary(defaultPath: "/bin/echo"), "/bin/echo",
                "a blank field is not a path; it means use the default")
    }

    T.test("praxis hook installs with NO matcher, surgically") {
        let splice = PraxisHookConfig.splice
        T.expect(splice.matcher == nil,
                 "praxis matches a matcher against the event's reason - Claude's "
                 + "notification_type pattern would match nothing and never fire")
        T.equal(splice.event, "Notification", "the alias praxis maps to attention_needed")

        // A settings file someone else already owns, including their own hook
        // on the same event.
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Notification": [["matcher": "theirs",
                                  "hooks": [["type": "command", "command": "/theirs.sh"]]]],
                "PreToolUse": [["hooks": [["type": "command", "command": "/other.sh"]]]],
            ],
        ]
        let installed = splice.install(into: existing, scriptPath: "/tmp/alert.sh")
        T.equal(installed["model"] as? String, "opus", "unknown keys survive")
        let entries = splice.entries(in: installed)
        T.equal(entries.count, 2, "their entry is kept and ours is appended")
        T.expect(splice.isInstalled(in: installed), "ours is found by its marker")

        let ours = entries.first { splice.isOurs($0) }
        T.expect(ours?["matcher"] == nil,
                 "no matcher key at all - an absent matcher means every occurrence")
        let steps = ours?["hooks"] as? [[String: Any]]
        T.expect((steps?.first?["command"] as? String)?.contains("/tmp/alert.sh") == true,
                 "runs our script")
        T.equal(steps?.first?["timeout"] as? Int, 5,
                "short timeout on an observation-only event")

        // Installing twice must not stack.
        let twice = splice.install(into: installed, scriptPath: "/tmp/alert.sh")
        T.equal(splice.entries(in: twice).filter { splice.isOurs($0) }.count, 1,
                "a second install replaces ours rather than duplicating it")

        // Removal takes ours and nothing else.
        let removed = splice.remove(from: twice)
        T.expect(!splice.isInstalled(in: removed), "ours is gone")
        T.equal(splice.entries(in: removed).count, 1, "theirs remains")
        T.expect((removed["hooks"] as? [String: Any])?["PreToolUse"] != nil,
                 "an unrelated event is untouched")

        // And when ours was the only entry, the keys are pruned rather than
        // left as empty husks.
        let solo = splice.install(into: [:], scriptPath: "/tmp/alert.sh")
        T.expect(splice.remove(from: solo)["hooks"] == nil,
                 "the hooks key is pruned when nothing is left")
    }

    T.test("a praxis attention payload decodes to the same vocabulary as Claude's") {
        let now = Date()
        // Real shape: praxis sends event/cwd/hook_event_name/session_id plus
        // the attention detail (reason, tool, question).
        let question = "{\"event\":\"attention_needed\",\"hook_event_name\":\"Notification\","
            + "\"session_id\":\"01a0a970-a677-7c25-aa11-35b2163b7b39\",\"cwd\":\"/tmp\","
            + "\"reason\":\"waiting_question\",\"tool\":\"ask\",\"question\":\"Ship it or wait?\"}"
        let asked = SessionAlert.decode(Data(question.utf8), at: now)
        T.equal(asked?.kind, "waiting_question", "praxis reason becomes the kind")
        T.equal(asked?.label, "Ship it or wait?",
                "the question itself is the label, better than any generic string")

        let permission = "{\"session_id\":\"01a0a970-a677-7c25-aa11-35b2163b7b39\","
            + "\"reason\":\"waiting_permission\",\"tool\":\"Bash\"}"
        T.equal(SessionAlert.decode(Data(permission.utf8), at: now)?.label,
                "Bash needs approval", "names the tool that stopped")

        // Claude's own shape still wins where it is present.
        let claude = "{\"session_id\":\"abc\",\"notification_type\":\"permission_prompt\","
            + "\"message\":\"Bash wants to run: npm test\"}"
        T.equal(SessionAlert.decode(Data(claude.utf8), at: now)?.label,
                "Bash wants to run: npm test", "Claude's wording is unchanged")

        let noSession = "{\"reason\":\"waiting_question\"}"
        T.expect(SessionAlert.decode(Data(noSession.utf8), at: now) == nil,
                 "no session id means nothing to attribute, so nothing is raised")
    }

    T.test("the praxis backend is gated off until the experiment flag is set") {
        let defaults = UserDefaults.standard
        let previousFlag = defaults.object(forKey: praxisBackendFlagKey)
        let previousPick = defaults.string(forKey: workBackendKey)
        defer {
            if let previousFlag { defaults.set(previousFlag, forKey: praxisBackendFlagKey) }
            else { defaults.removeObject(forKey: praxisBackendFlagKey) }
            if let previousPick { defaults.set(previousPick, forKey: workBackendKey) }
            else { defaults.removeObject(forKey: workBackendKey) }
        }

        // Someone who tried praxis and then lost the flag must not be stuck on
        // it: the flag wins over the stored selection, so turning it off is a
        // complete way back.
        defaults.set("praxis", forKey: workBackendKey)
        defaults.removeObject(forKey: praxisBackendFlagKey)
        T.expect(!Backend.praxisAvailable, "absent flag -> unavailable")
        T.equal(Backend.kind, .flow, "a stored praxis pick is ignored while the flag is off")
        T.equal(Backend.active().kind, .flow, "and the factory hands back the flow client")
        T.equal(Backend.selectable, [.flow], "a picker offers nothing to choose")

        defaults.set(false, forKey: praxisBackendFlagKey)
        T.equal(Backend.kind, .flow, "explicitly false is off too")

        defaults.set(true, forKey: praxisBackendFlagKey)
        T.expect(Backend.praxisAvailable, "flag on -> available")
        T.equal(Backend.kind, .praxis, "and the stored pick is honoured again")
        T.equal(Backend.selectable, BackendKind.allCases, "both backends are offered")
    }
}
