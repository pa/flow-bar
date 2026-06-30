import Foundation

/// One task as emitted by `flow list tasks --format json`.
///
/// Observed JSON keys (flow v0.1.0-alpha.23):
///   slug, name, status, priority, project, age_days, stale,
///   stale_days, waiting_on, live, updated, tags
/// Only `slug`, `name`, `status`, `priority` are assumed always-present;
/// everything else is optional to stay resilient to floating tasks
/// (no project) and future field drift.
public struct FlowTask: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var name: String
    public var status: String
    public var priority: String
    public var project: String?
    public var ageDays: Int?
    public var stale: Bool?
    public var staleDays: Int?
    public var waitingOn: String?
    public var live: Bool?
    public var updated: String?
    public var tags: [String]?
    public var assignee: String?
    public var due: String?
    public var dueInDays: Int?
    public var dueLabel: String?

    public var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, name, status, priority, project
        case ageDays = "age_days"
        case stale
        case staleDays = "stale_days"
        case waitingOn = "waiting_on"
        case live, updated, tags, assignee, due
        case dueInDays = "due_in_days"
        case dueLabel = "due_label"
    }

    /// Tolerant decoder: only `slug` is required. Everything else defaults, so
    /// one odd/incomplete row (a playbook-run, a future flow field change)
    /// can't fail the whole list. `name` falls back to the slug.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)   // only truly-required field
        name = (try? c.decode(String.self, forKey: .name)) ?? slug
        status = (try? c.decode(String.self, forKey: .status)) ?? "backlog"
        priority = (try? c.decode(String.self, forKey: .priority)) ?? "medium"
        project = try? c.decode(String.self, forKey: .project)
        ageDays = try? c.decode(Int.self, forKey: .ageDays)
        stale = try? c.decode(Bool.self, forKey: .stale)
        staleDays = try? c.decode(Int.self, forKey: .staleDays)
        waitingOn = try? c.decode(String.self, forKey: .waitingOn)
        live = try? c.decode(Bool.self, forKey: .live)
        updated = try? c.decode(String.self, forKey: .updated)
        tags = try? c.decode([String].self, forKey: .tags)
        assignee = try? c.decode(String.self, forKey: .assignee)
        due = try? c.decode(String.self, forKey: .due)
        dueInDays = try? c.decode(Int.self, forKey: .dueInDays)
        dueLabel = try? c.decode(String.self, forKey: .dueLabel)
    }

    // MARK: Convenience accessors (nil-safe for the UI layer)

    public var isStale: Bool { stale ?? false }
    public var isLive: Bool { live ?? false }
    public var isWaiting: Bool { (waitingOn?.isEmpty == false) }
    public var tagList: [String] { tags ?? [] }
    public var projectName: String? {
        guard let project, !project.isEmpty else { return nil }
        return project
    }

    public enum Priority: String { case high, medium, low }
    public var priorityValue: Priority { Priority(rawValue: priority) ?? .medium }

    /// Has a due date that is overdue or within the next few days.
    public var isDueSoon: Bool {
        guard let d = dueInDays else { return false }
        return d <= 3
    }
    public var isOverdue: Bool { (dueInDays ?? 1) < 0 }

    public init(
        slug: String, name: String, status: String, priority: String,
        project: String? = nil, ageDays: Int? = nil, stale: Bool? = nil,
        staleDays: Int? = nil, waitingOn: String? = nil, live: Bool? = nil,
        updated: String? = nil, tags: [String]? = nil, assignee: String? = nil,
        due: String? = nil, dueInDays: Int? = nil, dueLabel: String? = nil
    ) {
        self.slug = slug; self.name = name; self.status = status
        self.priority = priority; self.project = project; self.ageDays = ageDays
        self.stale = stale; self.staleDays = staleDays; self.waitingOn = waitingOn
        self.live = live; self.updated = updated; self.tags = tags
        self.assignee = assignee; self.due = due; self.dueInDays = dueInDays
        self.dueLabel = dueLabel
    }
}
