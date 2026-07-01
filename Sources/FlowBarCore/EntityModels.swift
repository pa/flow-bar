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

    public init(slug: String, name: String, priority: String, status: String,
                total: Int, inProgress: Int, backlog: Int, done: Int, updated: String?) {
        self.slug = slug; self.name = name; self.priority = priority; self.status = status
        self.total = total; self.inProgress = inProgress; self.backlog = backlog
        self.done = done; self.updated = updated
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
    public init(slug: String, status: String, playbook: String?) {
        self.slug = slug; self.status = status; self.playbook = playbook
    }
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

/// One progress note under a task's `updates/` dir.
public struct TaskUpdate: Identifiable, Hashable, Sendable {
    public var filename: String   // e.g. 2026-07-01-released-and-open-sourced.md
    public var date: String       // leading YYYY-MM-DD if present, else filename
    public var title: String      // humanised: "released and open sourced"
    public var content: String    // raw markdown
    public var id: String { filename }
    public init(filename: String, date: String, title: String, content: String) {
        self.filename = filename; self.date = date; self.title = title; self.content = content
    }
}

/// A task's readable detail: its brief and recent progress notes, assembled by
/// `FlowClient.taskDetail` from `flow show task` (for the file paths) + reading
/// those markdown files. Never touches flow.db.
public struct TaskDetail: Hashable, Sendable {
    public var slug: String
    public var name: String
    public var status: String            // backlog | in-progress | done
    public var archived: Bool
    public var brief: String            // brief.md content (may be empty)
    public var updates: [TaskUpdate]     // newest first
    public init(slug: String, name: String, status: String, archived: Bool = false,
                brief: String, updates: [TaskUpdate]) {
        self.slug = slug; self.name = name; self.status = status
        self.archived = archived; self.brief = brief; self.updates = updates
    }
    public var isDone: Bool { status == "done" }
    /// A done or archived task has nothing meaningful to switch to.
    public var canOpen: Bool { status != "done" && !archived }
}

/// Parsed `flow stats` output — flow's own "your AI memory did the
/// remembering" numbers (text, no JSON mode). Counts are exact; token/time
/// figures are flow's own estimates. All fields optional to stay resilient to
/// format drift (mirrors the tolerant list parsers). See `FlowClient.parseStats`.
public struct FlowStats: Sendable, Equatable {
    public var contextRecalls: Int?      // "flow recalled your context N times"
    public var resumes: Int?             // recall breakdown: resume …
    public var references: Int?          // … reference …
    public var crossTask: Int?           // … cross-task …
    public var kbRecalls: Int?           // … kb
    public var tokensReEstablished: Int? // "Context re-established : ~N tokens"
    public var instantResumes: Int?      // "Instant resumes : N×"
    public var tasksDone: Int?           // "Tasks done : N"
    public var kbFacts: Int?             // "KB facts : N"
    public var weeklyRecalls: String?    // sparkline glyphs, e.g. "▁▂▅█▃▄"

    public init(contextRecalls: Int? = nil, resumes: Int? = nil,
                references: Int? = nil, crossTask: Int? = nil, kbRecalls: Int? = nil,
                tokensReEstablished: Int? = nil, instantResumes: Int? = nil,
                tasksDone: Int? = nil, kbFacts: Int? = nil, weeklyRecalls: String? = nil) {
        self.contextRecalls = contextRecalls; self.resumes = resumes
        self.references = references; self.crossTask = crossTask
        self.kbRecalls = kbRecalls; self.tokensReEstablished = tokensReEstablished
        self.instantResumes = instantResumes; self.tasksDone = tasksDone
        self.kbFacts = kbFacts; self.weeklyRecalls = weeklyRecalls
    }

    /// Nothing worth showing — every headline field is missing/zero.
    public var isEmpty: Bool {
        (contextRecalls ?? 0) == 0 && (tokensReEstablished ?? 0) == 0
            && (instantResumes ?? 0) == 0 && (tasksDone ?? 0) == 0
    }
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

    /// Most-recently-updated first (nil `updated` last), then slug. Parses the
    /// ISO `updated` timestamp; falls back to a lexicographic ISO compare (which
    /// matches chronological order for same-format, same-offset timestamps).
    func sortedByRecentlyUpdated() -> [FlowTask] {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        func key(_ t: FlowTask) -> (Date?, String) {
            (t.updated.flatMap { fmt.date(from: $0) }, t.updated ?? "")
        }
        return sorted { a, b in
            let (da, sa) = key(a)
            let (db, sb) = key(b)
            if let da, let db, da != db { return da > db }
            if sa != sb { return sa > sb }
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
