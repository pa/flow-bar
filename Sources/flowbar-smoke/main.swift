import FlowBarCore
import Foundation

// Phase 1 smoke test: prove the flow -> JSON -> Codable path works end to end.
// Run with:  swift run flowbar-smoke

let client = FlowClient()

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
    let tasks = try client.inProgressTasks().filter(\.isLive)
    if tasks.isEmpty {
        print("  (no live sessions — start one with `flow do <slug>` to exercise this)")
    }
    for t in tasks {
        let info = try client.sessionInfo(t.slug)
        guard let sessionID = info.sessionID else {
            print("  \(t.slug): live, but flow reports no session_id  ← unexpected")
            continue
        }
        guard let located = SessionLocator.locate(sessionID: sessionID) else {
            print("  \(t.slug): session \(sessionID.prefix(8)) has no transcript "
                  + "under ~/.claude/projects or ~/.codex/sessions")
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
