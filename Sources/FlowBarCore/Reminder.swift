import Foundation

/// A flow-bar reminder — a user-set nudge delivered as a local macOS
/// notification at `fireDate`. It may be **standalone** (just a title/note) or
/// **linked** to a flow task (carries the slug/name and the flow-root profile
/// it lives under, so the Reminders view can offer to open it).
///
/// Pure model: no UI, no `UserNotifications`. Persistence is a plain JSON
/// round-trip of `[Reminder]` (see `encode`/`decode`); scheduling lives in the
/// app layer.
/// A task linked to a reminder. `profileID` records the flow-root profile the
/// task belongs to, so opening it can switch roots first.
public struct LinkedTask: Codable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var profileID: String?

    public init(slug: String, name: String, profileID: String? = nil) {
        self.slug = slug
        self.name = name.isEmpty ? slug : name
        self.profileID = profileID
    }

    public var id: String { slug }
}

public struct Reminder: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var note: String?
    public var fireDate: Date
    public var createdAt: Date
    /// Non-nil once completed; drives the "Completed" bucket.
    public var completedAt: Date?
    /// Linked tasks (empty for a standalone reminder). A reminder can gather
    /// several tasks.
    public var tasks: [LinkedTask]

    public init(id: UUID = UUID(), title: String, note: String? = nil,
                fireDate: Date, createdAt: Date = Date(), completedAt: Date? = nil,
                tasks: [LinkedTask] = []) {
        self.id = id
        self.title = title
        self.note = note
        self.fireDate = fireDate
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.tasks = tasks
    }

    public var isCompleted: Bool { completedAt != nil }
    public var isLinked: Bool { !tasks.isEmpty }

    /// Overdue = not completed and its fire time is in the past.
    public func isOverdue(_ now: Date = Date()) -> Bool {
        !isCompleted && fireDate < now
    }
}

/// Quick-fill presets for the create form. These only compute a `Date` for the
/// picker; the picker (date + time) remains the source of truth.
public enum ReminderPreset: Equatable {
    case inOneHour
    case thisEvening      // today 18:00
    case tomorrowMorning  // next day 09:00
    case atDue(Date)      // a task's due date at 09:00
    case custom

    /// Compute the preset's absolute date relative to `now`. Pure (calendar
    /// injectable) so it's testable. `.custom` returns nil (picker-driven).
    public func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .inOneHour:
            return now.addingTimeInterval(3600)
        case .thisEvening:
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .atDue(let due):
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
        case .custom:
            return nil
        }
    }
}

/// Buckets for the Reminders section, split by fire time relative to `now`.
public struct ReminderGroups: Equatable {
    public var overdue: [Reminder]
    public var today: [Reminder]
    public var upcoming: [Reminder]
    public var completed: [Reminder]

    public var isEmpty: Bool {
        overdue.isEmpty && today.isEmpty && upcoming.isEmpty && completed.isEmpty
    }
}

extension Array where Element == Reminder {
    /// Earliest fire first (used within each bucket).
    public func sortedByFire() -> [Reminder] {
        sorted { $0.fireDate < $1.fireDate }
    }

    /// Split into overdue / today / upcoming / completed. Completed reminders
    /// go to their own bucket regardless of fire time (newest-completed first);
    /// everything else is sorted by fire time within its bucket.
    public func group(now: Date = Date(), calendar: Calendar = .current) -> ReminderGroups {
        var overdue: [Reminder] = [], today: [Reminder] = [], upcoming: [Reminder] = []
        var completed: [Reminder] = []
        for r in self {
            if r.isCompleted { completed.append(r); continue }
            if r.fireDate < now {
                overdue.append(r)
            } else if calendar.isDate(r.fireDate, inSameDayAs: now) {
                today.append(r)
            } else {
                upcoming.append(r)
            }
        }
        return ReminderGroups(
            overdue: overdue.sortedByFire(),
            today: today.sortedByFire(),
            upcoming: upcoming.sortedByFire(),
            completed: completed.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
    }

    /// Count that warrants the rail badge: overdue + firing today.
    public func activeBadgeCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let g = group(now: now, calendar: calendar)
        return g.overdue.count + g.today.count
    }
}

/// JSON persistence helpers for the reminder list (used by the app-layer store).
public enum ReminderStore {
    public static func encode(_ reminders: [Reminder]) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(reminders)
    }

    public static func decode(_ data: Data) -> [Reminder] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Reminder].self, from: data)) ?? []
    }
}

/// One row of the rendered reminders list: a bucket heading, or a reminder.
///
/// The list used to be four sibling `ForEach` containers (Overdue / Today /
/// Upcoming / Completed) inside a single `LazyVStack`. That gave the lazy stack
/// four independent identity spaces over one reused cell pool, so as buckets
/// filled and emptied the headings drifted away from their rows — future,
/// uncompleted reminders ended up rendered under "COMPLETED".
///
/// Flattening to ONE list with one identity space makes a reminder changing
/// bucket an ordinary move, which SwiftUI handles correctly. It is also pure,
/// so the ordering is unit-testable rather than only observable by eye.
public enum ReminderListItem: Identifiable, Equatable {
    case header(String)
    case reminder(Reminder)

    /// A reminder is in exactly one bucket at a time, so its UUID is unique
    /// across the whole flattened list — which keeps `scrollTo(reminder.id)`
    /// working for notification focus.
    public var id: String {
        switch self {
        case .header(let label): return "header:\(label)"
        case .reminder(let r):   return r.id.uuidString
        }
    }
}

public extension ReminderGroups {
    /// Headings + rows in display order, omitting empty buckets.
    func flattened() -> [ReminderListItem] {
        var out: [ReminderListItem] = []
        for (label, items) in [("Overdue", overdue), ("Today", today),
                               ("Upcoming", upcoming), ("Completed", completed)] {
            guard !items.isEmpty else { continue }
            out.append(.header(label))
            out.append(contentsOf: items.map(ReminderListItem.reminder))
        }
        return out
    }
}
