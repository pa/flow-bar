import FlowBarCore
import Foundation

// MARK: - Line builders

/// Praxis names the *record*, not the speaker: every turn line is
/// `{"type":"message", …, "message":{"role":…}}`, threaded by `parentId`.
///
/// Every shape in this file was copied from a real
/// `~/.praxis/agent/sessions/<id>/session.jsonl` — trimmed of `usage` and
/// `provider` noise, but never reshaped. That matters more than usual here: a
/// fixture invented from the parser's own assumptions can only ever confirm the
/// parser. These were read off disk first, and the parser written against them.
private func praxis(_ ts: String, _ message: [String: Any]) -> [String: Any] {
    ["type": "message", "id": "01a0af89-13a9-7582-93e3-94676da5490f",
     "parentId": "01a0af89-13a9-75f7-b79c-121694b61a7f",
     "timestamp": ts, "message": message]
}

/// Line 1 of every praxis transcript, and the only line that carries the cwd.
private func praxisHeader(_ ts: String, cwd: String) -> [String: Any] {
    ["type": "session", "version": 3, "id": "01a0aecc-2dd7-76e5-bd16-2009685ecebf",
     "timestamp": ts, "cwd": cwd, "title": "can we health check", "titleSource": "user"]
}

/// An assistant turn that ends in tool calls: `stopReason` is `toolUse`, and the
/// call rides in the same line as the thinking that produced it.
private func praxisToolCall(_ id: String, _ name: String, _ ts: String) -> [String: Any] {
    praxis(ts, ["role": "assistant", "stopReason": "toolUse", "model": "claude-sonnet-4-5",
                "content": [["type": "thinking", "text": "Need to build.", "thinkingMs": 812],
                            ["type": "toolCall", "id": id, "name": name,
                             "arguments": ["command": "swift build"]]]])
}

/// Praxis gives results their own role rather than folding them into a user
/// entry, so nothing here has to be disambiguated from a typed prompt.
private func praxisToolResult(_ id: String, _ name: String, _ ts: String,
                              outcome: String = "success") -> [String: Any] {
    praxis(ts, ["role": "toolResult", "toolCallId": id, "toolName": name,
                "toolOutcome": outcome,
                "content": [["type": "text", "text": "ok (build complete)"]]])
}

private func praxisAssistantText(_ text: String, _ ts: String) -> [String: Any] {
    praxis(ts, ["role": "assistant", "stopReason": "stop",
                "content": [["type": "text", "text": text]]])
}

private func praxisUserPrompt(_ text: String, _ ts: String,
                              customType: String? = nil) -> [String: Any] {
    var message: [String: Any] = ["role": "user", "text": text]
    if let customType { message["customType"] = customType }
    return praxis(ts, message)
}

/// The clock these cases share, matching the base the Claude and Codex cases in
/// `main.swift` use so a reader can compare the three side by side.
private let praxisT0 = TranscriptTime.parse("2026-09-15T15:20:00.000Z")!
private func praxisAt(_ seconds: TimeInterval) -> Date {
    praxisT0.addingTimeInterval(seconds)
}

// MARK: - Cases

/// Locating and reading a praxis session transcript.
///
/// In its own file because `main.swift` is the only place top-level code may
/// live; `runPraxisTranscriptTests()` is called from there.
@MainActor
func runPraxisTranscriptTests() {
    print("\nTranscriptParser — praxis")

    T.test("the praxis header is where cwd comes from") {
        var p = TranscriptParser()
        p.consume(object: praxisHeader("2026-09-15T15:20:00.000Z", cwd: "/Users/p/dev/flow-bar"))
        T.equal(p.cwd, "/Users/p/dev/flow-bar", "cwd from the session header")
        // The header predates any turn, so it must not read as activity: a
        // session that has only been opened is `.unknown`, not `.thinking`.
        T.equal(p.activity(now: praxisAt(1)), .unknown, "opening a session is not activity")
        T.expect(p.lastEventAt == nil, "and the header does not stamp the clock")
    }

    T.test("a praxis tool call is opened by the call and closed by its result") {
        var p = TranscriptParser()
        p.consume(object: praxisToolCall("call_w33pjgs4", "bash", "2026-09-15T15:20:00.000Z"))
        T.equal(p.pending.map(\.name), ["bash"], "outstanding, named")
        T.equal(p.activity(now: praxisAt(3)), .working(tool: "bash", since: praxisT0),
                "3s in = working")
        T.equal(p.activity(now: praxisAt(9)), .waitingOnYou(tool: "bash", since: praxisT0),
                "same debounce as the other two — praxis records no permission state")
        p.consume(object: praxisToolResult("call_w33pjgs4", "bash", "2026-09-15T15:20:10.000Z"))
        T.equal(p.pending.count, 0, "closed on toolCallId")
        T.equal(p.activity(now: praxisAt(11)), .thinking(since: praxisAt(10)), "back to thinking")
    }

    T.test("a praxis result pairs on toolCallId, not on arrival order") {
        var p = TranscriptParser()
        p.consume(object: praxisToolCall("call_a", "read", "2026-09-15T15:20:00.000Z"))
        p.consume(object: praxisToolCall("call_b", "grep", "2026-09-15T15:20:01.000Z"))
        p.consume(object: praxisToolResult("call_b", "grep", "2026-09-15T15:20:02.000Z"))
        T.equal(p.pending.map(\.id), ["call_a"], "the right one is still outstanding")
        // A `refused` outcome is a *denied* permission arriving as an ordinary
        // result, which is why a denial never leaves a call hanging.
        p.consume(object: praxisToolResult("call_a", "read", "2026-09-15T15:20:03.000Z",
                                           outcome: "refused"))
        T.expect(p.pending.isEmpty, "a refusal closes the call like any other outcome")
    }

    T.test("praxis assistant text hands the turn back") {
        var p = TranscriptParser()
        p.consume(object: praxisUserPrompt("build it", "2026-09-15T15:20:00.000Z"))
        T.equal(p.activity(now: praxisAt(1)), .thinking(since: praxisT0), "a prompt starts a turn")
        p.consume(object: praxisAssistantText("Built clean.", "2026-09-15T15:20:04.000Z"))
        T.equal(p.lastEntry, .assistantText, "the turn ended with prose")
        T.equal(p.activity(now: praxisAt(5)), .awaitingPrompt(since: praxisAt(4)), "your turn")
    }

    T.test("stopReason ends a praxis turn even with nothing in it") {
        var p = TranscriptParser()
        p.consume(object: praxisToolCall("call_1", "bash", "2026-09-15T15:20:00.000Z"))
        // An interrupted turn is written with `content` absent entirely — 51 of
        // them in the sample this was read from. Reading only the blocks would
        // drop the line and leave the session reading as busy forever;
        // `stopReason` is what makes it say "your move" instead.
        p.consume(object: praxis("2026-09-15T15:20:03.000Z",
                                 ["role": "assistant", "stopReason": "aborted"]))
        T.expect(p.pending.isEmpty, "outstanding calls are moot once the turn ends")
        T.equal(p.activity(now: praxisAt(600)), .awaitingPrompt(since: praxisAt(3)),
                "your turn, and it stays that way")
    }

    T.test("praxis `ask` needs no debounce") {
        var p = TranscriptParser()
        p.consume(object: praxisToolCall("call_3d6hza6q", "ask", "2026-09-15T15:20:00.000Z"))
        T.equal(p.activity(now: praxisAt(0.5)), .waitingOnYou(tool: "ask", since: praxisT0),
                "blocked from the instant it is called")
        T.equal(p.activity(now: praxisAt(0.5)).label, "asking you", "and it says which kind")
    }

    T.test("a system-injected praxis turn is not the human typing") {
        var p = TranscriptParser()
        p.consume(object: praxisAssistantText("Done.", "2026-09-15T15:20:00.000Z"))
        // `customType` marks turns praxis injects itself — peer deliveries,
        // workspace moves, doctor repairs. Praxis's `isMeta`.
        p.consume(object: praxisUserPrompt("peer said hi", "2026-09-15T15:20:02.000Z",
                                           customType: "peer_delivery"))
        T.equal(p.lastEntry, .assistantText, "still the human's move")
        T.equal(p.activity(now: praxisAt(3)), .awaitingPrompt(since: praxisAt(2)),
                "an injected turn is not a new prompt")
    }

    T.test("praxis bookkeeping lines are skipped, not rejected") {
        var p = TranscriptParser()
        p.consume(object: praxisAssistantText("Done.", "2026-09-15T15:20:00.000Z"))
        let before = p.activity(now: praxisAt(1))
        // Real line kinds off disk, the reminder blocks praxis wraps every turn
        // in, and one that does not exist yet: a format addition has to degrade
        // to "no new information", never to a parse failure.
        p.consume(object: ["type": "todo_update", "timestamp": "2026-09-15T15:20:02.000Z",
                           "todos": [["content": "ship it", "status": "in-progress"]]])
        p.consume(object: ["type": "model_change", "timestamp": "2026-09-15T15:20:03.000Z",
                           "model": "claude-opus-4"])
        p.consume(object: ["type": "custom_message", "timestamp": "2026-09-15T15:20:04.000Z",
                           "customType": "context_rules", "display": false,
                           "content": "<system-reminder>a reminder</system-reminder>"])
        p.consume(object: praxis("2026-09-15T15:20:05.000Z",
                                 ["role": "custom", "customType": "memory_salience",
                                  "display": false, "content": "<system-reminder>another"]))
        p.consume(object: ["type": "something_praxis_adds_next",
                           "timestamp": "2026-09-15T15:20:06.000Z"])
        T.equal(p.malformedLines, 0, "an unknown line type is not a broken line")
        T.equal(p.activity(now: praxisAt(7)), before, "and it changes nothing")
    }

    T.test("a half-written praxis line still counts as malformed") {
        var p = TranscriptParser()
        // The counter exists to catch tail framing going wrong, so it has to
        // keep firing on real garbage while staying silent on the
        // unknown-but-valid lines above.
        p.consume(line: "{\"type\":\"message\",\"message\":{\"role\":\"assist")
        p.consume(line: "   ")
        T.equal(p.malformedLines, 1, "the truncated line, and only it")
    }

    print("\nSessionLocator — praxis")

    T.test("a praxis transcript is found at <agentDir>/sessions/<id>/session.jsonl") {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowbar-praxis-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let id = "01a0aecc-2dd7-76e5-bd16-2009685ecebf"
        let sessionDir = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcript = sessionDir.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        // Roots that exist and hold nothing, so a miss here is a real miss
        // rather than this machine's own ~/.claude quietly answering.
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)

        T.equal(SessionLocator.praxisTranscriptURL(sessionID: id, root: root), transcript,
                "a computed path, not a search")
        let found = SessionLocator.locate(sessionID: id, claudeRoot: empty, codexRoot: empty,
                                          praxisRoot: root, preferPraxis: true)
        T.equal(found?.url, transcript, "located")
        T.equal(found?.format, .praxis, "tagged as praxis")
        // Probed last rather than skipped when praxis is not the active backend,
        // so a session left running still resolves after a backend flip.
        T.equal(SessionLocator.locate(sessionID: id, claudeRoot: empty, codexRoot: empty,
                                      praxisRoot: root, preferPraxis: false)?.format, .praxis,
                "still found under the other backend")

        let bare = "01a0aecc-2dd7-76e5-bd16-2009685ecebe"
        try fm.createDirectory(at: root.appendingPathComponent(bare),
                               withIntermediateDirectories: true)
        T.expect(SessionLocator.praxisTranscriptURL(sessionID: bare, root: root) == nil,
                 "a session dir with no transcript in it is not a hit")
        T.expect(SessionLocator.praxisTranscriptURL(sessionID: "../../etc/passwd",
                                                    root: root) == nil,
                 "a malformed id never becomes a path component")
        T.expect(SessionLocator.locate(sessionID: bare, claudeRoot: empty, codexRoot: empty,
                                       praxisRoot: root, preferPraxis: true) == nil,
                 "and locate reports the miss rather than guessing")
    }

    T.test("a praxis transcript reads end to end through the tail") {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowbar-praxis-tail-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")

        // Real bytes through the real reader rather than objects handed straight
        // to the parser: line framing and per-line format sniffing meet here,
        // and only here. `sortedKeys` keeps the fixture byte-stable run to run.
        func line(_ obj: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var body = try line(praxisHeader("2026-09-15T15:20:00.000Z", cwd: "/Users/p/dev/flow-bar"))
        body += try line(praxisUserPrompt("build it", "2026-09-15T15:20:01.000Z"))
        body += try line(praxisToolCall("call_1", "bash", "2026-09-15T15:20:02.000Z"))
        try Data(body.utf8).write(to: url)

        let tail = TranscriptTail(url: url)
        T.expect(tail.refresh(), "read something")
        T.equal(tail.parser.cwd, "/Users/p/dev/flow-bar", "cwd survived the round trip")
        T.equal(tail.parser.malformedLines, 0, "framing held")
        T.equal(tail.activity(now: praxisAt(3)), .working(tool: "bash", since: praxisAt(2)),
                "working")

        // Append the result the way praxis does; only the delta is re-read.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let more = try line(praxisToolResult("call_1", "bash", "2026-09-15T15:20:05.000Z"))
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        T.expect(tail.refresh(), "picked up the appended result")
        T.equal(tail.activity(now: praxisAt(6)), .thinking(since: praxisAt(5)),
                "tool closed, turn continues")
    }

    // The case count lives with the other two in main.swift's "harness labels";
    // what is praxis-specific is its own label and that the raw value a
    // `Located` is persisted under round-trips.
    T.test("praxis is a harness like the other two") {
        T.equal(TranscriptFormat.praxis.label, "Praxis", "label")
        T.equal(TranscriptFormat(rawValue: "praxis"), .praxis, "round-trips by raw value")
    }
}
