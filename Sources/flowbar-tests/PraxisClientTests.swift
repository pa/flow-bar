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

    T.test("resume picks the newest session that is not still live") {
        // Oldest-first, as the CLI emits it.
        let segs: [(id: String, isOpen: Bool)] = [
            ("sess-old", false), ("sess-mid", false), ("sess-new", false),
        ]
        T.equal(PraxisClient.mostRecentResumable(segments: segs, live: []), "sess-new",
                "newest wins")
        // The newest is still running somewhere: resuming it would serve the
        // same session id twice, which shows an empty twin as the real one.
        T.equal(PraxisClient.mostRecentResumable(segments: segs, live: ["sess-new"]), "sess-mid",
                "a live session is skipped, not resumed")
        let withOpen: [(id: String, isOpen: Bool)] = [("sess-a", false), ("sess-b", true)]
        T.equal(PraxisClient.mostRecentResumable(segments: withOpen, live: []), "sess-a",
                "an open segment is skipped even when holders are not reported")
        T.expect(PraxisClient.mostRecentResumable(segments: [], live: []) == nil,
                 "no history -> nothing to resume")
        T.expect(PraxisClient.mostRecentResumable(segments: [("only", true)], live: ["only"]) == nil,
                 "every candidate live -> nothing to resume")
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
        defer {
            if let previous { defaults.set(previous, forKey: workBackendKey) }
            else { defaults.removeObject(forKey: workBackendKey) }
        }
        defaults.removeObject(forKey: workBackendKey)
        T.equal(Backend.kind, .flow, "absent setting → flow, so an existing install is unchanged")
        defaults.set("nonsense", forKey: workBackendKey)
        T.equal(Backend.kind, .flow, "unreadable setting → flow, never a crash")
        defaults.set("praxis", forKey: workBackendKey)
        T.equal(Backend.kind, .praxis, "praxis selected")
        T.equal(Backend.active().kind, .praxis, "factory follows the setting")
    }
}
