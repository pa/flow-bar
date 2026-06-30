import Foundation

/// A project from `flow list projects --format json`.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var name: String
    public var priority: String
    public var status: String
    public var total: Int
    public var inProgress: Int
    public var backlog: Int
    public var done: Int
    public var updated: String?

    public var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, name, priority, status, total
        case inProgress = "in_progress"
        case backlog, done, updated
    }
}

/// A playbook definition from `flow list playbooks --format json`.
public struct Playbook: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var project: String?
    public var id: String { slug }
}

/// A playbook run from `flow list runs --format json` (a task with
/// kind=playbook_run).
public struct PlaybookRun: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var status: String
    public var playbook: String?
    public var id: String { slug }
}

/// An owner from `flow owner list` (text output — no JSON mode).
public struct Owner: Identifiable, Hashable, Sendable {
    public var slug: String
    public var status: String       // active | paused | retired
    public var every: String        // e.g. "3h"
    public var nextTick: String?    // ISO timestamp
    public var nextTickRelative: String?  // e.g. "in 1h59m0s"
    public var id: String { slug }
    public init(slug: String, status: String, every: String,
                nextTick: String?, nextTickRelative: String?) {
        self.slug = slug; self.status = status; self.every = every
        self.nextTick = nextTick; self.nextTickRelative = nextTickRelative
    }
}

/// A tag + its task count from `flow list tags` (text output).
public struct TagCount: Identifiable, Hashable, Sendable {
    public var tag: String
    public var count: Int
    public var id: String { tag }
    public init(tag: String, count: Int) { self.tag = tag; self.count = count }
}

/// Aggregated, exact metrics for the Dashboard, computed from the JSON/text
/// lists. All counts are exact; nothing is estimated.
public struct DashboardMetrics: Sendable {
    public var inProgress: [FlowTask]
    public var backlogCount: Int
    public var doneCount: Int
    public var projects: [Project]
    public var runs: [PlaybookRun]
    public var owners: [Owner]
    public var tags: [TagCount]
    public var questions: [FlowTask]  // tasks tagged `question` (owner asks)

    public init(inProgress: [FlowTask], backlogCount: Int, doneCount: Int,
                projects: [Project], runs: [PlaybookRun], owners: [Owner],
                tags: [TagCount], questions: [FlowTask]) {
        self.inProgress = inProgress; self.backlogCount = backlogCount
        self.doneCount = doneCount; self.projects = projects; self.runs = runs
        self.owners = owners; self.tags = tags; self.questions = questions
    }

    public var inProgressCount: Int { inProgress.count }
    public var overdueCount: Int { inProgress.filter { $0.isOverdue }.count }
    public var staleCount: Int { inProgress.filter { $0.isStale }.count }
    public var liveCount: Int { inProgress.filter { $0.isLive }.count }
    public var waitingCount: Int { inProgress.filter { $0.isWaiting }.count }

    public var activeProjectCount: Int { projects.filter { $0.status == "active" }.count }
    public var activeOwnerCount: Int { owners.filter { $0.status == "active" }.count }
    public var questionCount: Int { questions.count }

    public var runsRunning: Int { runs.filter { $0.status == "in-progress" }.count }
    public var runsDone: Int { runs.filter { $0.status == "done" }.count }

    public var topTags: [TagCount] { Array(tags.prefix(8)) }
}

public extension Array where Element == FlowTask {
    /// Case-insensitive filter across slug / name / project / tags.
    func filtered(by query: String) -> [FlowTask] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return self }
        return filter { t in
            if t.slug.lowercased().contains(q) { return true }
            if t.name.lowercased().contains(q) { return true }
            if let p = t.projectName, p.lowercased().contains(q) { return true }
            if t.tagList.contains(where: { $0.lowercased().contains(q) }) { return true }
            return false
        }
    }

    /// High priority first, then by slug.
    func sortedByPriority() -> [FlowTask] {
        func rank(_ p: FlowTask.Priority) -> Int {
            switch p { case .high: return 0; case .medium: return 1; case .low: return 2 }
        }
        return sorted { a, b in
            if a.priority != b.priority { return rank(a.priorityValue) < rank(b.priorityValue) }
            return a.slug < b.slug
        }
    }

    /// Status order (in-progress, backlog, done), then priority, then slug.
    func sortedByStatusThenPriority() -> [FlowTask] {
        func statusRank(_ s: String) -> Int {
            switch s { case "in-progress": return 0; case "backlog": return 1; default: return 2 }
        }
        func prioRank(_ p: FlowTask.Priority) -> Int {
            switch p { case .high: return 0; case .medium: return 1; case .low: return 2 }
        }
        return sorted { a, b in
            if a.status != b.status { return statusRank(a.status) < statusRank(b.status) }
            if a.priority != b.priority { return prioRank(a.priorityValue) < prioRank(b.priorityValue) }
            return a.slug < b.slug
        }
    }
}
