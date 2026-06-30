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
