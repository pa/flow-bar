import CoreGraphics
import FlowBarCore
import Foundation

// Unit tests for the pure FlowBarCore logic. Run: swift run flowbar-tests

func task(_ slug: String, name: String = "", status: String = "in-progress",
          priority: String = "medium", project: String? = nil, stale: Bool? = nil,
          live: Bool? = nil, waitingOn: String? = nil, dueInDays: Int? = nil,
          tags: [String]? = nil, updated: String? = nil,
          archived: Bool? = nil) -> FlowTask {
    FlowTask(slug: slug, name: name, status: status, priority: priority,
             project: project, stale: stale, waitingOn: waitingOn, live: live,
             updated: updated, tags: tags, dueInDays: dueInDays, archived: archived)
}

// MARK: - Model decoding

print("Models")
T.test("decode full task") {
    let json = """
    {"slug":"frammer-ondemand-cost-report","name":"Daily report","status":"in-progress",
     "priority":"high","project":"cost-management","age_days":21,"due":"2026-06-13",
     "due_in_days":-17,"due_label":"overdue 17d","stale":true,"stale_days":21,"live":true,
     "waiting_on":"customer approval","updated":"2026-06-09T17:12:11+05:30","tags":["aws","frammer"]}
    """.data(using: .utf8)!
    let t = try JSONDecoder().decode(FlowTask.self, from: json)
    T.equal(t.slug, "frammer-ondemand-cost-report", "slug")
    T.equal(t.priorityValue, .high, "priority")
    T.equal(t.projectName, "cost-management", "project")
    T.equal(t.dueInDays, -17, "dueInDays")
    T.expect(t.isOverdue, "isOverdue")
    T.expect(t.isDueSoon, "isDueSoon (overdue)")
    T.expect(t.isStale, "isStale")
    T.expect(t.isLive, "isLive")
    T.expect(t.isWaiting, "isWaiting")
    T.equal(t.tagList, ["aws", "frammer"], "tags")
}

T.test("decode minimal floating task") {
    let json = #"{"slug":"x","name":"X","status":"backlog","priority":"medium"}"#.data(using: .utf8)!
    let t = try JSONDecoder().decode(FlowTask.self, from: json)
    T.expect(t.projectName == nil, "floating → nil project")
    T.expect(!t.isStale && !t.isLive && !t.isWaiting && !t.isOverdue && !t.isDueSoon, "no flags")
    T.expect(t.tagList.isEmpty, "no tags")
}

T.test("empty project string is floating") {
    let json = #"{"slug":"x","name":"X","status":"backlog","priority":"low","project":""}"#.data(using: .utf8)!
    let t = try JSONDecoder().decode(FlowTask.self, from: json)
    T.expect(t.projectName == nil, "empty project → nil")
}

T.test("decode project maps in_progress") {
    let json = #"{"slug":"p","name":"P","priority":"medium","status":"active","total":2,"in_progress":1,"backlog":1,"done":0}"#.data(using: .utf8)!
    let p = try JSONDecoder().decode(Project.self, from: json)
    T.equal(p.inProgress, 1, "in_progress")
    T.equal(p.total, 2, "total")
}

print("Due/overdue boundaries")
T.expect(task("a", dueInDays: 3).isDueSoon, "3d is due-soon")
T.expect(!task("a", dueInDays: 4).isDueSoon, "4d not due-soon")
T.expect(task("a", dueInDays: -1).isOverdue, "-1d overdue")
T.expect(!task("a", dueInDays: 0).isOverdue, "0d not overdue")
T.expect(!task("a").isDueSoon, "no due → not soon")

// MARK: - Filter / sort

print("Filter & sort")
let sample = [
    task("audit", name: "AWS cost analysis", project: "cost-management", tags: ["integrtr"]),
    task("oauth", name: "Add login", project: "budget", tags: ["frontend"]),
]
T.equal(sample.filtered(by: "audit").map(\.slug), ["audit"], "filter by slug")
T.equal(sample.filtered(by: "login").map(\.slug), ["oauth"], "filter by name")
T.equal(sample.filtered(by: "cost").map(\.slug), ["audit"], "filter by project")
T.equal(sample.filtered(by: "frontend").map(\.slug), ["oauth"], "filter by tag")
T.equal(sample.filtered(by: "AUDIT").map(\.slug), ["audit"], "case-insensitive")
T.equal(sample.filtered(by: "").count, 2, "empty filter = all")
T.expect(sample.filtered(by: "zzz").isEmpty, "no match")

let prioritized = [
    task("c", priority: "low"), task("a", priority: "high"),
    task("b", priority: "medium"), task("a2", priority: "high"),
]
T.equal(prioritized.sortedByPriority().map(\.slug), ["a", "a2", "b", "c"], "sort by priority")

let byUpdated = [
    task("old", updated: "2026-06-01T10:00:00+05:30"),
    task("newest", updated: "2026-07-01T09:00:00+05:30"),
    task("mid", updated: "2026-06-15T12:00:00+05:30"),
    task("nodate", updated: nil),
]
T.equal(byUpdated.sortedByRecentlyUpdated().map(\.slug), ["newest", "mid", "old", "nodate"],
        "sort by recently updated (nil last)")

let mixed = [
    task("done1", status: "done", priority: "high"),
    task("bl", status: "backlog", priority: "high"),
    task("ip-lo", status: "in-progress", priority: "low"),
    task("ip-hi", status: "in-progress", priority: "high"),
]
T.equal(mixed.sortedByStatusThenPriority().map(\.slug), ["ip-hi", "ip-lo", "bl", "done1"],
        "sort by status then priority")

// MARK: - Parsers

print("Parsers")
let ownerText = """
SLUG                 STATUS   EVERY  NEXT TICK
granola-intake       active   3h     2026-06-30T20:09:18+05:30  (in 1h59m0s)
paused-one           paused   24h    2026-07-01T09:00:00+05:30  (in 14h)
"""
let owners = FlowClient.parseOwners(ownerText)
T.equal(owners.count, 2, "owners count")
T.equal(owners.first?.slug, "granola-intake", "owner slug")
T.equal(owners.first?.status, "active", "owner status")
T.equal(owners.first?.every, "3h", "owner interval")
T.equal(owners.first?.nextTick, "2026-06-30T20:09:18+05:30", "owner nextTick")
T.equal(owners.first?.nextTickRelative, "in 1h59m0s", "owner relative")
T.expect(FlowClient.parseOwners("SLUG STATUS EVERY NEXT TICK\n\n").isEmpty, "owners header/blank skipped")

// `flow owner list` has no --format json and prints PROSE when there are no
// owners. A positional parser turned that into a bogus owner (slug "No",
// status "owners."), which is what surfaced as a junk row in the Owners view.
T.expect(FlowClient.parseOwners(
    #"No owners. Create one with: flow add owner "<name>" --work-dir <path> --every <dur>"#
).isEmpty, "owners empty-state prose yields no rows")

// The NEXT TICK column can be a bare parenthesised state instead of a
// timestamp; that must not be mistaken for an ISO date.
let ownerNoTick = FlowClient.parseOwners("""
SLUG                 STATUS   EVERY  NEXT TICK
probe-owner          active   3h     (not started)
""")
T.equal(ownerNoTick.count, 1, "owner with no scheduled tick parses")
T.equal(ownerNoTick.first?.nextTick, nil, "no ISO timestamp when state is parenthesised")
T.equal(ownerNoTick.first?.nextTickRelative, "not started", "parenthesised state kept as relative")
T.equal(FlowClient.parseOwners("""
SLUG                 STATUS   EVERY  NEXT TICK
probe-owner          paused   3h     (paused)
""").first?.status, "paused", "paused owner still parses")

let tagText = """
TAG                    COUNT
#frammer               36 tasks
#owner:granola-intake  2 tasks
"""
let tags = FlowClient.parseTags(tagText)
T.equal(tags.count, 2, "tags count")
T.equal(tags.first?.tag, "frammer", "tag '#' stripped")
T.equal(tags.first?.count, 36, "tag count")
T.equal(tags.last?.tag, "owner:granola-intake", "kv tag")
T.expect(FlowClient.parseTags("TAG COUNT").isEmpty, "tags header skipped")

// Same class of bug as owners: with nothing tagged, `flow list tags` prints
// "(no tags in use)", which became a tag named "(no" with count 0.
T.expect(FlowClient.parseTags("(no tags in use)").isEmpty, "tags empty-state prose yields no rows")
T.expect(FlowClient.parseTags("#alpha  not-a-number").isEmpty, "non-numeric count rejected")

// listTags prefers `flow list tags --format json`, whose shape is
// [{"tag": "...", "count": N}] with no leading '#'.
let tagJSON = Data(#"[{"tag":"alpha","count":2},{"tag":"beta","count":1}]"#.utf8)
let decodedTags = try! JSONDecoder().decode([TagCount].self, from: tagJSON)
T.equal(decodedTags.count, 2, "tags decode from flow's json")
T.equal(decodedTags.first?.tag, "alpha", "json tag name")
T.equal(decodedTags.first?.count, 2, "json tag count")

// MARK: - Slugify

print("Slugify")
T.equal(slugify("Add OAuth login!"), "add-oauth-login", "lowercased, punctuation stripped")
T.equal(slugify("Tighten checkout capture timeout on slow networks"), "tighten-checkout-capture-timeout-on-slow", "capped at 6 words")
T.equal(slugify("PCI audit"), "pci-audit", "simple")
T.equal(slugify("  spaced   out  "), "spaced-out", "collapses whitespace")

// MARK: - Version compare

print("Version")
T.expect(isVersion("0.1.10", newerThan: "0.1.9"), "0.1.10 > 0.1.9 (numeric, not lexical)")
T.expect(isVersion("v0.2.0", newerThan: "0.1.9"), "leading v tolerated")
T.expect(!isVersion("0.1.9", newerThan: "0.1.9"), "equal is not newer")
T.expect(!isVersion("0.1.8", newerThan: "0.1.9"), "older is not newer")
T.expect(isVersion("1.0.0", newerThan: "0.9.9"), "major bump")
T.expect(!isVersion("0.1.9-beta", newerThan: "0.1.9"), "pre-release suffix ignored → not newer")

// MARK: - Archived decode

print("Archived")
let archJSON = #"[{"slug":"a","name":"A","status":"backlog","priority":"high","archived":true},{"slug":"b","name":"B","status":"done","priority":"low"}]"#
let archTasks = try! JSONDecoder().decode([FlowTask].self, from: archJSON.data(using: .utf8)!)
T.expect(archTasks[0].isArchived, "archived:true decodes")
T.expect(!archTasks[1].isArchived, "missing archived key → not archived")

// MARK: - flow stats

print("Stats")
let statsText = """
flow stats — all-time

  Your AI remembered, so you didn't.
  flow recalled your context 346 times — you never re-explained it.
    resume 68 · reference 53 · cross-task 187 · kb 38

  Memory
    Context re-established : ~701,842 tokens you never re-typed (est.)
    Instant resumes        : 68× — flow dropped you straight back into work

  Shipped
    Tasks done       : 71
    Tokens processed : 5,011,319,778
    KB facts         : 260

  Addressed by name, not a UUID : 240
  Weekly recalls   : ▁▁▂▁▅█▃▄▁▄▁
"""
let st = FlowClient.parseStats(statsText)
T.equal(st.contextRecalls, 346, "context recalls")
T.equal(st.resumes, 68, "recall breakdown: resume")
T.equal(st.references, 53, "recall breakdown: reference")
T.equal(st.crossTask, 187, "recall breakdown: cross-task")
T.equal(st.kbRecalls, 38, "recall breakdown: kb")
T.equal(st.tokensReEstablished, 701842, "tokens re-established (commas stripped)")
T.equal(st.instantResumes, 68, "instant resumes (not the breakdown resume)")
T.equal(st.tasksDone, 71, "tasks done")
T.equal(st.kbFacts, 260, "kb facts")
T.equal(st.weeklyRecalls, "▁▁▂▁▅█▃▄▁▄▁", "weekly recalls sparkline")
T.expect(!st.isEmpty, "stats not empty")
T.expect(FlowClient.parseStats("").isEmpty, "empty stats input → isEmpty")

// MARK: - show task paths

print("Show task paths")
let showText = """
slug:          flow-bar
name:          Build flow-bar menubar app
status:        in-progress
work_dir:      /Users/x/dev/flow-bar  [known]
brief:         /Users/x/.flow/tasks/flow-bar/brief.md
updates:
  - /Users/x/.flow/tasks/flow-bar/updates/2026-06-30-v1-built.md
  - /Users/x/.flow/tasks/flow-bar/updates/2026-07-01-released.md
other:         (none)
kb:
  - /Users/x/.flow/kb/user.md
  - /Users/x/.flow/kb/org.md
"""
let paths = FlowClient.parseShowPaths(showText)
T.equal(paths.name, "Build flow-bar menubar app", "show: name")
T.equal(paths.status, "in-progress", "show: status")
T.expect(!paths.archived, "show: not archived")
T.equal(paths.brief, "/Users/x/.flow/tasks/flow-bar/brief.md", "show: brief path")
let archivedPaths = FlowClient.parseShowPaths("slug:  x  (archived)\nstatus:  backlog\narchived:  2026-05-10T18:55:46+05:30\n")
T.expect(archivedPaths.archived, "show: archived flag from archived: line")
T.equal(paths.updates.count, 2, "show: only updates collected, not kb")
T.equal(paths.updates.last, "/Users/x/.flow/tasks/flow-bar/updates/2026-07-01-released.md", "show: last update")
let (upDate, upTitle) = FlowClient.splitUpdateName("2026-07-01-released-and-open-sourced.md")
T.equal(upDate, "2026-07-01", "update date parsed")
T.equal(upTitle, "released and open sourced", "update title humanised")
let (nonDate, _) = FlowClient.splitUpdateName("notes.md")
T.equal(nonDate, "notes", "non-dated update falls back to base name")

let detail = TaskDetail(
    slug: "flow-bar", name: "Build flow-bar", status: "in-progress", brief: "## What\nA menubar app.",
    updates: [TaskUpdate(filename: "2026-07-01-shipped.md", date: "2026-07-01", title: "shipped", content: "Released v1.")])
let clip = detail.clipboardText
T.expect(clip.contains("# Build flow-bar"), "clipboard has title")
T.expect(clip.contains("A menubar app."), "clipboard has brief")
T.expect(clip.contains("### 2026-07-01 — shipped"), "clipboard has update header")
T.expect(clip.contains("Released v1."), "clipboard has update body")

// MARK: - Dashboard metrics

print("Metrics")
let m = DashboardMetrics(
    inProgress: [
        task("a", stale: true, dueInDays: -2),
        task("b", live: true),
        task("c", waitingOn: "x"),
        task("d"),
    ],
    backlogCount: 7, doneCount: 12,
    projects: [
        Project(slug: "p1", name: "P1", priority: "medium", status: "active",
                total: 3, inProgress: 1, backlog: 1, done: 1, updated: nil),
        Project(slug: "p2", name: "P2", priority: "low", status: "done",
                total: 1, inProgress: 0, backlog: 0, done: 1, updated: nil),
    ],
    runs: [PlaybookRun(slug: "r1", status: "in-progress", playbook: "pb"),
           PlaybookRun(slug: "r2", status: "done", playbook: "pb")],
    owners: [Owner(slug: "o1", status: "active", every: "3h", nextTick: nil, nextTickRelative: nil),
             Owner(slug: "o2", status: "paused", every: "24h", nextTick: nil, nextTickRelative: nil)],
    tags: (1...10).map { TagCount(tag: "t\($0)", count: $0) },
    questions: [task("q1"), task("q2")])

T.equal(m.inProgressCount, 4, "inProgressCount")
T.equal(m.overdueCount, 1, "overdueCount")
T.equal(m.staleCount, 1, "staleCount")
T.equal(m.liveCount, 1, "liveCount")
T.equal(m.waitingCount, 1, "waitingCount")
T.equal(m.activeProjectCount, 1, "activeProjectCount")
T.equal(m.activeOwnerCount, 1, "activeOwnerCount")
T.equal(m.questionCount, 2, "questionCount")
T.equal(m.runsRunning, 1, "runsRunning")
T.equal(m.runsDone, 1, "runsDone")
T.equal(m.topTags.count, 8, "topTags capped at 8")

// MARK: - Reminders

print("Reminders")

T.test("reminder codable round-trip") {
    let r = Reminder(
        id: UUID(), title: "Ship v2", note: "notes",
        fireDate: Date(timeIntervalSince1970: 1_900_000_000),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        completedAt: nil,
        tasks: [LinkedTask(slug: "flow-bar", name: "flow bar", profileID: "default"),
                LinkedTask(slug: "flow", name: "flow", profileID: "default")])
    let data = ReminderStore.encode([r])!
    let back = ReminderStore.decode(data)
    T.equal(back.count, 1, "count")
    T.equal(back.first?.tasks.count, 2, "two linked tasks survive")
    T.equal(back.first?.tasks.first?.slug, "flow-bar", "slug survives")
    T.equal(back.first, r, "equal round trip")
    T.expect(back.first?.isLinked == true, "isLinked")
}

do {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = 8
    comps.hour = 10; comps.minute = 0; comps.second = 0
    let cal = Calendar.current
    let now = cal.date(from: comps)!

    T.test("preset inOneHour") {
        let d = ReminderPreset.inOneHour.date(from: now)!
        T.equal(d.timeIntervalSince(now), 3600, "one hour later")
    }
    T.test("preset thisEvening = 18:00 same day") {
        let d = ReminderPreset.thisEvening.date(from: now, calendar: cal)!
        let c = cal.dateComponents([.day, .hour, .minute], from: d)
        T.equal(c.hour, 18, "evening hour"); T.equal(c.day, 8, "same day")
    }
    T.test("preset tomorrowMorning = next day 09:00") {
        let d = ReminderPreset.tomorrowMorning.date(from: now, calendar: cal)!
        let c = cal.dateComponents([.day, .hour], from: d)
        T.equal(c.hour, 9, "morning hour"); T.equal(c.day, 9, "next day")
    }
    T.test("custom preset has no date") {
        T.expect(ReminderPreset.custom.date(from: now) == nil, "custom is picker-driven")
    }
}

T.test("reminder grouping buckets") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let cal = Calendar.current
    let overdue = Reminder(title: "o", fireDate: now.addingTimeInterval(-3600))
    let soon = Reminder(title: "t", fireDate: now.addingTimeInterval(1800))
    let later = Reminder(title: "u", fireDate: now.addingTimeInterval(8 * 24 * 3600))
    var done = Reminder(title: "d", fireDate: now.addingTimeInterval(-7200))
    done.completedAt = now
    let g = [later, overdue, done, soon].group(now: now, calendar: cal)
    T.equal(g.overdue.count, 1, "one overdue")
    T.equal(g.completed.count, 1, "one completed")
    T.equal(g.today.count + g.upcoming.count, 2, "two pending non-overdue")
    T.expect(overdue.isOverdue(now), "overdue flag")
    T.expect(!soon.isOverdue(now), "future not overdue")
}

T.test("reminders sort by fire time") {
    let base = Date(timeIntervalSince1970: 1_900_000_000)
    let a = Reminder(title: "a", fireDate: base.addingTimeInterval(300))
    let b = Reminder(title: "b", fireDate: base.addingTimeInterval(100))
    let c = Reminder(title: "c", fireDate: base.addingTimeInterval(200))
    let sorted = [a, b, c].sortedByFire()
    T.equal(sorted.map { $0.title }, ["b", "c", "a"], "earliest first")
}


// Completing a reminder must move it OUT of its time bucket and into
// Completed — including the overdue case, which is the one that matters most
// (an overdue item you've dealt with should stop nagging).
T.test("completing an overdue reminder moves it to Completed") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var r = Reminder(id: UUID(), title: "pay invoice", note: nil,
                     fireDate: now.addingTimeInterval(-3600), createdAt: now)
    let before = [r].group(now: now)
    T.equal(before.overdue.count, 1, "starts overdue")
    T.equal(before.completed.count, 0, "not yet completed")
    T.expect(r.isOverdue(now), "isOverdue before completing")

    r.completedAt = now
    let after = [r].group(now: now)
    T.equal(after.overdue.count, 0, "leaves the Overdue bucket")
    T.equal(after.completed.count, 1, "lands in Completed")
    T.expect(!r.isOverdue(now), "a completed reminder is never overdue")
}

T.test("completing clears the rail badge") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var overdue = Reminder(id: UUID(), title: "a", note: nil,
                           fireDate: now.addingTimeInterval(-60), createdAt: now)
    var todayItem = Reminder(id: UUID(), title: "b", note: nil,
                             fireDate: now.addingTimeInterval(60), createdAt: now)
    T.equal([overdue, todayItem].activeBadgeCount(now: now), 2, "both count toward the badge")
    overdue.completedAt = now
    todayItem.completedAt = now
    T.equal([overdue, todayItem].activeBadgeCount(now: now), 0, "completed items don't badge")
}

T.test("Completed bucket is newest-completed first") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var older = Reminder(id: UUID(), title: "older", note: nil, fireDate: now, createdAt: now)
    var newer = Reminder(id: UUID(), title: "newer", note: nil, fireDate: now, createdAt: now)
    older.completedAt = now.addingTimeInterval(-600)
    newer.completedAt = now
    T.equal([older, newer].group(now: now).completed.map { $0.title }, ["newer", "older"],
            "most recently completed first")
}

T.test("un-completing returns a reminder to its time bucket") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var r = Reminder(id: UUID(), title: "back", note: nil,
                     fireDate: now.addingTimeInterval(-3600), createdAt: now,
                     completedAt: now)
    T.equal([r].group(now: now).completed.count, 1, "starts completed")
    r.completedAt = nil
    let g = [r].group(now: now)
    T.equal(g.completed.count, 0, "leaves Completed")
    T.equal(g.overdue.count, 1, "returns to Overdue")
}

// The compose form refuses to save unless the fire time is in the FUTURE, so a
// stale carried-over date silently disables Add. Encode that rule here so the
// "reminder won't save and nothing explains why" failure can't come back.
T.test("a past fire date must not be savable") {
    let past = Date().addingTimeInterval(-60)
    let future = Date().addingTimeInterval(3600)
    T.expect(!(past > Date()), "a past date fails the save guard")
    T.expect(future > Date(), "the default (+1h) passes the save guard")
}

// The rendered list is now one flat [header, rows…] sequence. These pin the
// exact bug that was visible on screen: two FUTURE, uncompleted reminders
// rendered underneath the "COMPLETED" heading, with no "UPCOMING" heading at
// all — because four sibling ForEach containers were sharing one LazyVStack
// cell pool and the headings drifted off their rows.
T.test("flattened list keeps each reminder under its own heading") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let cal = Calendar.current
    let upcomingA = Reminder(id: UUID(), title: "nothing", note: nil,
                             fireDate: now.addingTimeInterval(86_400), createdAt: now)
    let upcomingB = Reminder(id: UUID(), title: "test", note: nil,
                             fireDate: now.addingTimeInterval(90_000), createdAt: now)
    var done = Reminder(id: UUID(), title: "smoke test", note: nil,
                        fireDate: now.addingTimeInterval(-3600), createdAt: now)
    done.completedAt = now

    let flat = [upcomingA, upcomingB, done].group(now: now, calendar: cal).flattened()
    let labels: [String] = flat.map {
        switch $0 {
        case .header(let l):   return "#\(l)"
        case .reminder(let r): return r.title
        }
    }
    T.equal(labels, ["#Upcoming", "nothing", "test", "#Completed", "smoke test"],
            "headings stay attached to their own rows")
}

T.test("empty buckets emit no heading") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var done = Reminder(id: UUID(), title: "only", note: nil, fireDate: now, createdAt: now)
    done.completedAt = now
    let flat = [done].group(now: now).flattened()
    T.equal(flat.count, 2, "one heading + one row")
    T.equal(flat.first?.id, "header:Completed", "only the Completed heading")
}

T.test("flattened ids are unique so cells can't be reused across buckets") {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var done = Reminder(id: UUID(), title: "a", note: nil,
                        fireDate: now.addingTimeInterval(-60), createdAt: now)
    done.completedAt = now
    let live = Reminder(id: UUID(), title: "b", note: nil,
                        fireDate: now.addingTimeInterval(86_400), createdAt: now)
    let ids = [done, live].group(now: now).flattened().map { $0.id }
    T.equal(ids.count, Set(ids).count, "no duplicate ids in the rendered list")
    T.expect(ids.contains(live.id.uuidString), "a reminder's id is its UUID (scrollTo still works)")
}

// MARK: - Multi-select

print("Multi-select")

// canOpen gates which rows get a checkbox. Gating at CHECK time (not open time)
// means the user gets immediate feedback instead of items silently vanishing
// from a batch.
T.expect(task("a", status: "in-progress").canOpen, "in-progress is openable")
T.expect(task("b", status: "backlog").canOpen, "backlog is openable (matches single-click)")
T.expect(!task("c", status: "done").canOpen, "done is not openable")
var archived = task("d", status: "in-progress"); archived.archived = true
T.expect(!archived.canOpen, "archived is not openable")

// `visible` must compose exactly as the old inline logic did, since the list
// and Enter-to-open now both route through it.
let msTasks = [
    task("low-one",  priority: "low",    updated: "2026-01-03T00:00:00+00:00"),
    task("high-one", priority: "high",   updated: "2026-01-01T00:00:00+00:00"),
    task("mid-one",  priority: "medium", updated: "2026-01-02T00:00:00+00:00"),
]
T.equal(msTasks.visible(query: "", sort: TaskListSort.priority).map(\.slug),
        msTasks.filtered(by: "").sortedByPriority().map(\.slug),
        "visible(.priority) == filtered+sortedByPriority")
T.equal(msTasks.visible(query: "", sort: TaskListSort.recentlyUpdated).map(\.slug),
        msTasks.filtered(by: "").sortedByRecentlyUpdated().map(\.slug),
        "visible(.recentlyUpdated) matches")
T.equal(msTasks.visible(query: "", sort: TaskListSort.statusThenPriority).map(\.slug),
        msTasks.filtered(by: "").sortedByStatusThenPriority().map(\.slug),
        "visible(.statusThenPriority) matches")

// Enter must skip rows flow do can't act on, rather than firing a no-op.
let withDoneFirst = [
    task("aaa-done", status: "done", priority: "high"),
    task("bbb-live", status: "in-progress", priority: "high"),
]
T.equal(withDoneFirst.firstOpenable(query: "", sort: TaskListSort.priority)?.slug, "bbb-live",
        "firstOpenable skips a done first row")

// The pre-existing bug: Enter ignored the search box and opened the global
// first task instead of the first MATCH.
T.equal(msTasks.firstOpenable(query: "mid", sort: TaskListSort.priority)?.slug, "mid-one",
        "firstOpenable respects the query")
T.equal([task("x", status: "done")].firstOpenable(query: "", sort: TaskListSort.priority)?.slug, nil,
        "firstOpenable is nil when nothing is openable")

// The action bar's counts. `hidden` is what proves to the user that checks made
// before they re-searched are still live.
let sum = selectionSummary(selected: ["a", "b", "c"], visibleSlugs: ["a", "z"])
T.equal(sum.total, 3, "summary total")
T.equal(sum.visible, 1, "summary visible")
T.equal(sum.hidden, 2, "summary hidden by search")

// A checked slug that has left the list entirely (task completed elsewhere,
// filter changed) still counts and is never silently dropped — the slug is all
// `flow do` needs.
let goneSum = selectionSummary(selected: ["vanished"], visibleSlugs: [])
T.equal(goneSum.total, 1, "unknown slug still counted")
T.equal(goneSum.hidden, 1, "unknown slug counts as hidden")

// Batch order is deterministic so error text is stable across runs.
T.equal(Set(["c", "a", "b"]).sorted(), ["a", "b", "c"], "batch order is deterministic")

print("Markdown blocks")

// flow briefs are hard-wrapped at ~72 columns, so a paragraph arrives as
// several source lines. Re-joining them is the whole reason the old per-line
// renderer produced ragged text.
T.equal(Markdown.parse("""
one two
three four

next para
"""),
        [.paragraph("one two three four"), .paragraph("next para")],
        "soft-wrapped lines join into one paragraph")

T.equal(Markdown.parse("# Title\n## Sub\n### Deep"),
        [.heading(level: 1, text: "Title"),
         .heading(level: 2, text: "Sub"),
         .heading(level: 3, text: "Deep")],
        "ATX headings by level")

// "#hashtag" is not a heading — a heading needs the space.
T.equal(Markdown.parse("#flow is a tag"), [.paragraph("#flow is a tag")],
        "no space after # is not a heading")

let fenced = Markdown.parse("""
before

```sh
swift build
swift run flowbar-tests
```

after
""")
T.equal(fenced, [.paragraph("before"),
                 .code(language: "sh", code: "swift build\nswift run flowbar-tests"),
                 .paragraph("after")],
        "fenced code keeps its language and its own line breaks")

// An unterminated fence runs to end of input rather than swallowing nothing.
T.equal(Markdown.parse("```\nstuck"), [.code(language: nil, code: "stuck")],
        "unterminated fence still yields a code block")

// A tilde fence must not be closed by a backtick fence.
T.equal(Markdown.parse("~~~\na ``` b\n~~~"),
        [.code(language: nil, code: "a ``` b")],
        "tilde fence ignores backticks inside")

T.equal(Markdown.parse("""
| a | b |
|---|---|
| 1 | 2 |
| 3 | 4 |
"""),
        [.table(header: ["a", "b"], rows: [["1", "2"], ["3", "4"]])],
        "pipe table with header and rows")

// A pipe line without a delimiter row underneath is just prose.
T.equal(Markdown.parse("a | b"), [.paragraph("a | b")],
        "pipes without a delimiter row are not a table")

T.equal(Markdown.parse("> quoted\n> still quoted\n\nout"),
        [.quote("quoted still quoted"), .paragraph("out")],
        "blockquote joins its lines")
T.equal(Markdown.parse("> one\n>\n> two"),
        [.quote("one\n\ntwo")],
        "a bare > is a paragraph break inside the quote")

T.equal(Markdown.parse("""
- top
  - nested
- [x] done
- [ ] todo
1. first
2) second
"""),
        [.listItem(indent: 0, kind: .bullet, text: "top"),
         .listItem(indent: 1, kind: .bullet, text: "nested"),
         .listItem(indent: 0, kind: .checkbox(true), text: "done"),
         .listItem(indent: 0, kind: .checkbox(false), text: "todo"),
         .listItem(indent: 0, kind: .ordered(1), text: "first"),
         .listItem(indent: 0, kind: .ordered(2), text: "second")],
        "bullets, nesting, checkboxes and ordered markers")

// A wrapped list item's continuation lines belong to the item, not to a new
// paragraph — every "Done when" bullet in a flow brief looks like this.
T.equal(Markdown.parse("- item text that\n  wraps onto a second line\n\nafter"),
        [.listItem(indent: 0, kind: .bullet, text: "item text that wraps onto a second line"),
         .paragraph("after")],
        "list continuation lines fold into the item")

T.equal(Markdown.parse("above\n\n---\n\nbelow"),
        [.paragraph("above"), .rule, .paragraph("below")],
        "--- is a horizontal rule")
// The table delimiter row contains pipes, so it must never read as a rule.
T.equal(Markdown.parse("| h |\n|---|\n| v |"),
        [.table(header: ["h"], rows: [["v"]])],
        "delimiter row is not mistaken for a rule")

// Inline markup is deliberately left in the text for the renderer to parse.
T.equal(Markdown.parse("some **bold** and `code`"),
        [.paragraph("some **bold** and `code`")],
        "inline syntax is preserved verbatim in the block text")

T.equal(Markdown.parse(""), [], "empty input yields no blocks")
T.equal(Markdown.parse("\n\n  \n"), [], "whitespace-only input yields no blocks")

print("Done & archived drill-ins")

// flow hides done tasks unless asked, and archived ones separately. A project
// row advertises a done count, so the drill-in must ask for both or it
// contradicts its own header.
T.equal(FlowClient.listTasksArgs(project: "flow-bar", includeDone: true, includeArchived: true),
        ["list", "tasks", "--project", "flow-bar",
         "--include-done", "--include-archived", "--format", "json"],
        "project drill-in asks for done + archived")
T.equal(FlowClient.listTasksArgs(tag: "swift", includeDone: true, includeArchived: true),
        ["list", "tasks", "--tag", "swift",
         "--include-done", "--include-archived", "--format", "json"],
        "tag drill-in asks for done + archived")
// The polled in-progress list must NOT start dragging in done rows.
T.equal(FlowClient.listTasksArgs(status: "in-progress"),
        ["list", "tasks", "--status", "in-progress", "--format", "json"],
        "in-progress poll is unchanged")
// A playbook run is not hidden behind a flag the way a done task is — it is
// absent from `flow list tasks` entirely until `--kind` asks for it. The
// session watcher must ask; the Tasks list must not (it would mix synthetic
// run rows into the switcher).
T.equal(FlowClient.listTasksArgs(status: "in-progress", kind: "all"),
        ["list", "tasks", "--status", "in-progress", "--kind", "all", "--format", "json"],
        "session watcher asks for playbook runs too")

let drillIn = [
    task("done-high", status: "done", priority: "high"),
    task("live-low", status: "in-progress", priority: "low"),
    task("backlog-high", status: "backlog", priority: "high"),
    task("archived-one", status: "in-progress", priority: "high", archived: true),
]
let split = drillIn.splitByActivity()
T.equal(split.active.map(\.slug), ["live-low", "backlog-high"],
        "active keeps in-progress before backlog")
T.equal(split.finished.map(\.slug), ["archived-one", "done-high"],
        "finished collects done AND archived")
T.expect(!split.isEmpty, "a split with rows is not empty")
T.expect([FlowTask]().splitByActivity().isEmpty, "an empty list splits to empty")

// An archived in-progress task is finished, not active — `flow do` can't act
// on it, which is exactly the line the separator draws.
T.equal([task("a", status: "in-progress", archived: true)].splitByActivity().active.count, 0,
        "archived never counts as active")

// MARK: - Session transcripts (island)

print("\nTranscriptTime")
T.test("parse the shape Claude Code writes") {
    let d = TranscriptTime.parse("2026-09-15T15:20:08.482Z")
    T.expect(d != nil, "parses fractional-second UTC")
    // 2026-09-15T15:20:08Z == 1789226408 epoch seconds.
    T.equal(d.map { Int($0.timeIntervalSince1970) }, 1_789_485_608, "epoch seconds")
    T.expect(abs((d?.timeIntervalSince1970 ?? 0) - 1_789_485_608.482) < 0.001, "fraction kept")
}
T.test("parse without fractional seconds") {
    T.equal(TranscriptTime.parse("2026-09-15T15:20:08Z").map { Int($0.timeIntervalSince1970) },
            1_789_485_608, "no-fraction form")
}
T.test("reject shapes we do not understand") {
    // A wrong timestamp would make the "waiting on you" badge lie, so anything
    // unfamiliar must come back nil rather than be guessed at.
    T.expect(TranscriptTime.parse("") == nil, "empty")
    T.expect(TranscriptTime.parse("2026-09-15") == nil, "date only")
    T.expect(TranscriptTime.parse("2026-09-15T15:20:08+05:30") == nil, "non-UTC offset")
    T.expect(TranscriptTime.parse("2026-13-15T15:20:08Z") == nil, "month 13")
    T.expect(TranscriptTime.parse("2026-09-15T25:20:08Z") == nil, "hour 25")
    T.expect(TranscriptTime.parse("not-a-timestamp-at-all") == nil, "garbage")
}
T.test("epoch day zero") {
    T.equal(TranscriptTime.daysFromCivil(year: 1970, month: 1, day: 1), 0, "1970-01-01")
    T.equal(TranscriptTime.daysFromCivil(year: 2000, month: 3, day: 1), 11_017, "2000-03-01")
}

print("\nTranscriptParser")

/// Build one assistant `tool_use` line.
func toolUse(_ id: String, _ name: String, _ ts: String) -> [String: Any] {
    ["type": "assistant", "timestamp": ts,
     "message": ["content": [["type": "tool_use", "id": id, "name": name]]]]
}
/// Build one user `tool_result` line.
func toolResult(_ id: String, _ ts: String) -> [String: Any] {
    ["type": "user", "timestamp": ts,
     "message": ["content": [["type": "tool_result", "tool_use_id": id]]]]
}
func assistantText(_ text: String, _ ts: String) -> [String: Any] {
    ["type": "assistant", "timestamp": ts,
     "message": ["content": [["type": "text", "text": text]]]]
}
func userPrompt(_ text: String, _ ts: String, isMeta: Bool = false) -> [String: Any] {
    ["type": "user", "timestamp": ts, "isMeta": isMeta, "message": ["content": text]]
}
let t0 = TranscriptTime.parse("2026-09-15T15:20:00.000Z")!
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

T.test("an unresolved tool_use becomes waiting-on-you past the debounce") {
    var p = TranscriptParser()
    p.consume(object: toolUse("t1", "Bash", "2026-09-15T15:20:00.000Z"))
    T.equal(p.pending.count, 1, "one outstanding")
    // Inside the window it is merely working...
    T.equal(p.activity(now: at(3)), .working(tool: "Bash", since: t0), "3s in = working")
    T.equal(p.activity(now: at(7.99)), .working(tool: "Bash", since: t0), "just under = working")
    // ...and at the boundary it flips.
    T.equal(p.activity(now: at(8)), .waitingOnYou(tool: "Bash", since: t0), "8s = waiting")
    T.equal(p.activity(now: at(60)), .waitingOnYou(tool: "Bash", since: t0), "still waiting")
}

T.test("a matching tool_result clears the pending state") {
    var p = TranscriptParser()
    p.consume(object: toolUse("t1", "Bash", "2026-09-15T15:20:00.000Z"))
    p.consume(object: toolResult("t1", "2026-09-15T15:20:02.000Z"))
    T.equal(p.pending.count, 0, "cleared")
    T.equal(p.activity(now: at(60)), .thinking(since: at(2)),
            "after a result the assistant is thinking, not waiting")
}

T.test("parallel tool calls resolve out of order and age from the oldest") {
    var p = TranscriptParser()
    p.consume(object: toolUse("a", "Read", "2026-09-15T15:20:00.000Z"))
    p.consume(object: toolUse("b", "Grep", "2026-09-15T15:20:01.000Z"))
    p.consume(object: toolResult("a", "2026-09-15T15:20:01.500Z"))
    T.equal(p.pending.map { $0.id }, ["b"], "only b outstanding")
    // The badge must age from the oldest SURVIVING call, not the oldest ever.
    T.equal(p.activity(now: at(8)), .working(tool: "Grep", since: at(1)),
            "b is only 7s old, so still working")
    T.equal(p.activity(now: at(9)), .waitingOnYou(tool: "Grep", since: at(1)), "b crosses at 9s")
}

T.test("a turn that ends in text is your move") {
    var p = TranscriptParser()
    p.consume(object: userPrompt("do the thing", "2026-09-15T15:20:00.000Z"))
    T.equal(p.activity(now: at(1)), .thinking(since: t0), "prompt in, no reply yet")
    p.consume(object: assistantText("done", "2026-09-15T15:20:05.000Z"))
    T.equal(p.activity(now: at(600)), .awaitingPrompt(since: at(5)),
            "assistant finished — waiting for the human, however long")
}

T.test("a system-injected user entry is not a new prompt") {
    var p = TranscriptParser()
    p.consume(object: assistantText("done", "2026-09-15T15:20:00.000Z"))
    p.consume(object: userPrompt("<system-reminder>…", "2026-09-15T15:20:01.000Z", isMeta: true))
    T.equal(p.activity(now: at(2)), .awaitingPrompt(since: at(1)),
            "isMeta must not flip the session back to thinking")
}

T.test("an abandoned tool call stops claiming your attention") {
    var p = TranscriptParser()
    p.consume(object: toolUse("t1", "Bash", "2026-09-15T15:20:00.000Z"))
    // Half an hour later this is debris — a killed session, or a transcript we
    // joined mid-stream. Badging it forever would train the user to ignore it.
    T.equal(p.activity(now: at(1_801)), .unknown, "past abandonAfter it is dropped")
    T.expect(!p.activity(now: at(1_801)).needsAttention, "and stops demanding attention")
}

T.test("thresholds are honored") {
    var p = TranscriptParser()
    p.consume(object: toolUse("t1", "Bash", "2026-09-15T15:20:00.000Z"))
    let eager = SessionActivity.Thresholds(debounce: 3)
    T.equal(p.activity(now: at(4), thresholds: eager),
            .waitingOnYou(tool: "Bash", since: t0), "a 3s debounce fires at 4s")
    let patient = SessionActivity.Thresholds(debounce: 20)
    T.equal(p.activity(now: at(10), thresholds: patient),
            .working(tool: "Bash", since: t0), "a 20s debounce does not")
}

T.test("nextTransition is armed only while a tool is outstanding") {
    var p = TranscriptParser()
    T.expect(p.nextTransition(now: at(0)) == nil, "nothing pending, no timer")
    p.consume(object: toolUse("t1", "Bash", "2026-09-15T15:20:00.000Z"))
    T.expect(abs((p.nextTransition(now: at(2)) ?? 0) - 6) < 0.001, "6s left of an 8s debounce")
    T.expect(p.nextTransition(now: at(8)) == nil, "already fired, nothing more to schedule")
    p.consume(object: toolResult("t1", "2026-09-15T15:20:09.000Z"))
    T.expect(p.nextTransition(now: at(9)) == nil, "resolved, timer disarmed")
}

T.test("unknown and malformed lines degrade instead of failing") {
    var p = TranscriptParser()
    // The line types Claude Code interleaves that carry no activity.
    for t in ["mode", "attachment", "ai-title", "permission-mode", "file-history-snapshot"] {
        p.consume(object: ["type": t, "sessionId": "x"])
    }
    T.equal(p.activity(now: at(1)), .unknown, "no activity inferred from noise")
    p.consume(line: "{not json")
    p.consume(line: "")
    T.equal(p.malformedLines, 1, "blank lines are not malformed, broken JSON is")
    // A real entry still lands after the noise.
    p.consume(line: #"{"type":"assistant","timestamp":"2026-09-15T15:20:05.000Z","message":{"content":[{"type":"text","text":"hi"}]}}"#)
    T.equal(p.activity(now: at(6)), .awaitingPrompt(since: at(5)), "recovers")
}

T.test("a tool_use with no timestamp can never be aged into an alert") {
    var p = TranscriptParser()
    p.consume(object: ["type": "assistant",
                       "message": ["content": [["type": "tool_use", "id": "t", "name": "Bash"]]]])
    T.equal(p.pending.count, 0, "dropped rather than anchored to now")
    T.equal(p.activity(now: at(60)), .unknown, "no invented age")
}

T.test("attention ordering puts the alerting states first") {
    let states: [SessionActivity] = [
        .unknown, .thinking(since: nil), .working(tool: "Bash", since: t0),
        .awaitingPrompt(since: nil), .waitingOnYou(tool: "Bash", since: t0),
    ]
    // A blocked row's label names the *kind* of block; "Bash" outstanding past
    // the debounce in a prompting mode means it's awaiting approval.
    T.equal(states.sorted { $0.rank < $1.rank }.map(\.label),
            ["needs approval", "your turn", "bash", "thinking", "unknown"],
            "sort order")
    T.expect(SessionActivity.waitingOnYou(tool: "x", since: t0).needsAttention, "alerts")
    T.expect(!SessionActivity.awaitingPrompt(since: nil).needsAttention, "your-turn does not badge")
}

print("\nTranscriptParser — what actually counts as blocked")

/// A Claude `permission-mode` line.
func permMode(_ mode: String) -> [String: Any] {
    ["type": "permission-mode", "permissionMode": mode, "sessionId": "s"]
}

T.test("AskUserQuestion blocks immediately — no debounce at all") {
    var p = TranscriptParser()
    p.consume(object: permMode("auto"))
    p.consume(object: toolUse("q1", "AskUserQuestion", "2026-09-15T15:20:00.000Z"))
    // Measured in a real transcript: AskUserQuestion sat for 62 minutes while
    // every Bash call in the same session finished in 0.1s median. There is
    // nothing to infer — the tool's whole job is to stop and ask.
    T.equal(p.activity(now: at(0.2)), .waitingOnYou(tool: "AskUserQuestion", since: t0),
            "blocked from the first instant")
    T.equal(p.activity(now: at(0.2)).label, "asking you", "says what kind of block")
    T.expect(p.activity(now: at(0.2)).needsAttention, "alerts")
}

T.test("ExitPlanMode blocks immediately too") {
    var p = TranscriptParser()
    p.consume(object: permMode("plan"))
    p.consume(object: toolUse("e1", "ExitPlanMode", "2026-09-15T15:20:00.000Z"))
    T.equal(p.activity(now: at(0.1)).label, "plan approval", "plan approval")
    T.expect(p.activity(now: at(0.1)).needsAttention, "alerts")
}

T.test("a slow Bash in auto mode is NEVER a permission prompt") {
    var p = TranscriptParser()
    p.consume(object: permMode("auto"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    // This is the false alarm that made the old rule untrustworthy: a real
    // session had Bash run for 10.3s with nothing blocked. In auto mode the
    // classifier answers immediately, so a hang is a slow command, full stop.
    T.equal(p.activity(now: at(11)), .working(tool: "Bash", since: t0), "11s — still just working")
    T.equal(p.activity(now: at(600)), .working(tool: "Bash", since: t0), "10 minutes — still working")
    T.expect(!p.activity(now: at(600)).needsAttention, "never alerts")
}

T.test("bypassPermissions likewise never infers a prompt") {
    var p = TranscriptParser()
    p.consume(object: permMode("bypassPermissions"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    T.expect(!p.activity(now: at(600)).needsAttention, "nothing to prompt about")
}

T.test("in a prompting mode a stuck tool DOES read as awaiting approval") {
    var p = TranscriptParser()
    p.consume(object: permMode("default"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    T.equal(p.activity(now: at(3)), .working(tool: "Bash", since: t0), "under the debounce")
    T.equal(p.activity(now: at(9)), .waitingOnYou(tool: "Bash", since: t0), "past it")
    T.equal(p.activity(now: at(9)).label, "needs approval", "labelled as approval")
}

T.test("acceptEdits still prompts for non-edit tools") {
    var p = TranscriptParser()
    p.consume(object: permMode("acceptEdits"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    T.expect(p.mayPrompt, "acceptEdits auto-approves edits, not commands")
    T.expect(p.activity(now: at(9)).needsAttention, "so a stuck Bash can still be a prompt")
}

T.test("an unknown mode is assumed to prompt") {
    var p = TranscriptParser()
    p.consume(object: permMode("someFutureMode"))
    T.expect(p.mayPrompt, "missing a real alert beats inventing a silent one")
    // ...and so is a transcript that never states a mode.
    T.expect(TranscriptParser().mayPrompt, "no mode reported")
}

T.test("a blocking tool wins even when an ordinary one is older") {
    var p = TranscriptParser()
    p.consume(object: permMode("auto"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    p.consume(object: toolUse("q1", "AskUserQuestion", "2026-09-15T15:20:30.000Z"))
    // The Bash is older, but the question is the thing that is actually stopped
    // on the human — reporting "bash" here would name the wrong cause.
    T.equal(p.activity(now: at(31)), .waitingOnYou(tool: "AskUserQuestion", since: at(30)),
            "the question is what's blocking")
}

T.test("answering the question unblocks, even with the Bash still running") {
    var p = TranscriptParser()
    p.consume(object: permMode("auto"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    p.consume(object: toolUse("q1", "AskUserQuestion", "2026-09-15T15:20:05.000Z"))
    p.consume(object: toolResult("q1", "2026-09-15T15:21:00.000Z"))
    T.expect(!p.activity(now: at(70)).needsAttention, "no longer blocked")
    T.equal(p.activity(now: at(70)), .working(tool: "Bash", since: t0), "back to the slow Bash")
}

T.test("with the hook active, the debounce guess is switched off entirely") {
    var p = TranscriptParser()
    p.consume(object: permMode("default"))
    p.consume(object: toolUse("b1", "Bash", "2026-09-15T15:20:00.000Z"))
    // A slow tool that a `permissions.allow` rule auto-approved raises no
    // prompt at all, yet the debounce would fire on it. Once Claude Code is
    // telling us about real prompts directly, the guess can only add mistakes.
    let exact = SessionActivity.Thresholds(inferPermissionPrompts: false)
    T.equal(p.activity(now: at(600), thresholds: exact), .working(tool: "Bash", since: t0),
            "never inferred while the hook is in effect")
    T.expect(!p.activity(now: at(600), thresholds: exact).needsAttention, "so no alert")
    // Without the hook it is the only fallback there is, so it still works.
    T.expect(p.activity(now: at(600)).needsAttention, "inferred when the hook is absent")
}

T.test("an exact block still fires with the guess switched off") {
    var p = TranscriptParser()
    p.consume(object: permMode("default"))
    p.consume(object: toolUse("q1", "AskUserQuestion", "2026-09-15T15:20:00.000Z"))
    let exact = SessionActivity.Thresholds(inferPermissionPrompts: false)
    // Turning off the *guess* must not turn off the things we actually know.
    T.expect(p.activity(now: at(1), thresholds: exact).needsAttention, "AskUserQuestion")
    var c = TranscriptParser()
    c.consume(object: codex("exec_approval_request", "2026-09-15T15:20:00.000Z",
                            outer: "event_msg"))
    T.expect(c.activity(now: at(1), thresholds: exact).needsAttention, "Codex approval")
}

T.test("permission mode is read from an entry field too, not just its own line") {
    var p = TranscriptParser()
    p.consume(object: ["type": "user", "timestamp": "2026-09-15T15:20:00.000Z",
                       "permissionMode": "bypassPermissions",
                       "message": ["content": "go"]])
    T.equal(p.permissionMode, "bypassPermissions", "taken from the user entry")
    T.expect(!p.mayPrompt, "and honoured")
}

T.test("Codex approval_policy maps onto the same gate") {
    var p = TranscriptParser()
    p.consume(object: ["type": "turn_context", "timestamp": "2026-09-15T15:20:00.000Z",
                       "payload": ["approval_policy": "never", "cwd": "/tmp/x"]])
    T.expect(!p.mayPrompt, "`never` will not ask")
    p.consume(object: codex("function_call", "2026-09-15T15:20:01.000Z",
                            ["call_id": "c1", "name": "exec_command"]))
    T.expect(!p.activity(now: at(600)).needsAttention, "so a long command never alerts")
}

T.test("an explicit Codex approval beats the mode gate") {
    var p = TranscriptParser()
    p.consume(object: ["type": "turn_context", "timestamp": "2026-09-15T15:20:00.000Z",
                       "payload": ["approval_policy": "never"]])
    p.consume(object: codex("exec_approval_request", "2026-09-15T15:20:01.000Z",
                            outer: "event_msg"))
    // If Codex asked, it asked — whatever we thought the policy was.
    T.expect(p.activity(now: at(2)).needsAttention, "an actual request always counts")
}

print("\nTranscriptParser — Codex")

/// Codex wraps everything in `payload`; Claude puts it in `message`.
func codex(_ payloadType: String, _ ts: String, outer: String = "response_item",
           _ extra: [String: Any] = [:]) -> [String: Any] {
    var payload: [String: Any] = ["type": payloadType]
    payload.merge(extra) { _, new in new }
    return ["type": outer, "timestamp": ts, "payload": payload]
}

T.test("the format is sniffed per line, not declared") {
    var p = TranscriptParser()
    // One parser, fed both dialects, keeps a single coherent state machine.
    p.consume(object: codex("session_meta", "2026-09-15T15:20:00.000Z", outer: "session_meta",
                            ["cwd": "/Users/p/dev/x", "id": "abc"]))
    T.equal(p.cwd, "/Users/p/dev/x", "cwd from Codex session_meta")
    p.consume(object: assistantText("hi", "2026-09-15T15:20:01.000Z"))
    T.equal(p.activity(now: at(2)), .awaitingPrompt(since: at(1)), "Claude line still parses")
}

T.test("Codex function calls pair on call_id") {
    var p = TranscriptParser()
    p.consume(object: codex("function_call", "2026-09-15T15:20:00.000Z",
                            ["call_id": "call_1", "name": "exec_command"]))
    T.equal(p.pending.count, 1, "outstanding")
    T.equal(p.activity(now: at(2)), .working(tool: "exec_command", since: t0), "working")
    T.equal(p.activity(now: at(9)), .waitingOnYou(tool: "exec_command", since: t0),
            "same debounce as Claude")
    p.consume(object: codex("function_call_output", "2026-09-15T15:20:10.000Z",
                            ["call_id": "call_1"]))
    T.equal(p.pending.count, 0, "cleared")
    T.equal(p.activity(now: at(11)), .thinking(since: at(10)), "back to thinking")
}

T.test("Codex custom_tool_call pairs the same way") {
    var p = TranscriptParser()
    p.consume(object: codex("custom_tool_call", "2026-09-15T15:20:00.000Z",
                            ["call_id": "c1", "name": "apply_patch"]))
    T.equal(p.pending.map(\.name), ["apply_patch"], "tracked")
    p.consume(object: codex("custom_tool_call_output", "2026-09-15T15:20:01.000Z",
                            ["call_id": "c1"]))
    T.expect(p.pending.isEmpty, "cleared")
}

T.test("an approval request needs no debounce — Codex says so outright") {
    var p = TranscriptParser()
    p.consume(object: codex("function_call", "2026-09-15T15:20:00.000Z",
                            ["call_id": "c1", "name": "exec_command"]))
    p.consume(object: codex("exec_approval_request", "2026-09-15T15:20:00.500Z",
                            outer: "event_msg", ["call_id": "c1"]))
    // Half a second in — under ANY debounce — and it already reads as blocked,
    // because this is a fact rather than an inference.
    T.expect(p.awaitingApproval, "flag set")
    T.equal(p.activity(now: at(0.6)), .waitingOnYou(tool: "exec_command", since: t0),
            "immediate, no waiting for the debounce")
    T.expect(p.activity(now: at(0.6)).needsAttention, "and it badges")
}

T.test("apply_patch approval requests are recognised too") {
    var p = TranscriptParser()
    p.consume(object: codex("apply_patch_approval_request", "2026-09-15T15:20:00.000Z",
                            outer: "event_msg"))
    T.expect(p.awaitingApproval, "any *_approval_request counts")
    T.expect(p.activity(now: at(1)).needsAttention, "badges with no pending tool")
}

T.test("an approval is cleared by whatever resolves it") {
    for resolver in ["function_call_output", "task_complete", "user_message"] {
        var p = TranscriptParser()
        p.consume(object: codex("exec_approval_request", "2026-09-15T15:20:00.000Z",
                                outer: "event_msg"))
        T.expect(p.awaitingApproval, "set before \(resolver)")
        let outer = resolver == "function_call_output" ? "response_item" : "event_msg"
        p.consume(object: codex(resolver, "2026-09-15T15:20:05.000Z", outer: outer,
                                ["call_id": "c1"]))
        T.expect(!p.awaitingApproval, "cleared by \(resolver)")
    }
}

T.test("task_complete ends the turn outright") {
    var p = TranscriptParser()
    p.consume(object: codex("function_call", "2026-09-15T15:20:00.000Z",
                            ["call_id": "c1", "name": "exec_command"]))
    p.consume(object: codex("task_complete", "2026-09-15T15:20:03.000Z", outer: "event_msg"))
    // Claude has to infer this from a debounce; Codex states it, so a tool left
    // dangling at the end of a turn can never masquerade as a live prompt.
    T.expect(p.pending.isEmpty, "outstanding calls are moot once the turn ends")
    T.equal(p.activity(now: at(600)), .awaitingPrompt(since: at(3)), "your turn, indefinitely")
}

T.test("a Codex turn in flight reads as thinking") {
    var p = TranscriptParser()
    p.consume(object: codex("task_started", "2026-09-15T15:20:00.000Z", outer: "event_msg"))
    T.equal(p.activity(now: at(1)), .thinking(since: t0), "task_started")
    p.consume(object: codex("agent_message", "2026-09-15T15:20:04.000Z", outer: "event_msg"))
    T.equal(p.activity(now: at(5)), .awaitingPrompt(since: at(4)), "agent_message ends it")
}

T.test("Codex noise carries no activity") {
    var p = TranscriptParser()
    for kind in ["token_count", "reasoning", "web_search_call", "patch_apply_end"] {
        p.consume(object: codex(kind, "2026-09-15T15:20:00.000Z"))
    }
    T.equal(p.activity(now: at(1)), .unknown, "nothing inferred from bookkeeping")
}

T.test("harness labels") {
    T.equal(TranscriptFormat.claude.label, "Claude", "claude")
    T.equal(TranscriptFormat.codex.label, "Codex", "codex")
    T.equal(TranscriptFormat.allCases.count, 3, "the two flow bootstraps, plus praxis")
}

print("\nBrewUpgrade — the self-upgrade script")

let upgradeScript = BrewUpgrade.script(
    appPath: "/Applications/flow-bar.app",
    bundleID: "cloud.facets.flow-bar",
    logPath: "/Users/me/Library/Logs/flow-bar-upgrade.log",
    markerPath: "/Users/me/Library/Application Support/flow-bar/last-upgrade",
    processMatch: "flow-bar.app/Contents/MacOS/flow-bar")

T.test("it refreshes the tap before upgrading") {
    // Without this the command is a lie: with a stale tap, `brew outdated`
    // reported nothing while a new version was already published.
    let pullAt = upgradeScript.range(of: "git -C \"$TAP_REPO\" pull --ff-only")
    let upgradeAt = upgradeScript.range(of: "brew upgrade --cask flow-bar")
    T.expect(pullAt != nil, "pulls the tap")
    T.expect(upgradeAt != nil, "upgrades the cask")
    if let p = pullAt, let u = upgradeAt {
        T.expect(p.lowerBound < u.lowerBound, "and pulls BEFORE upgrading")
    }
}

T.test("it always records an outcome, success or failure") {
    // The app is not running when the result is known, so the marker is the
    // only channel back. A path that writes nothing would look like "no upgrade
    // ever ran" and the failure would vanish.
    T.expect(upgradeScript.contains("printf 'ok' > \"$MARKER\""), "ok marker")
    T.expect(upgradeScript.contains("printf 'failed' > \"$MARKER\""), "failed marker")
    T.equal(upgradeScript.components(separatedBy: "printf 'failed'").count - 1, 2,
            "failed is written for a brew failure AND for a missing brew")
}

T.test("it relaunches the app on every path") {
    // Relaunching is both the recovery and the only progress signal the user
    // gets, so no branch may exit without it — including the brew-not-found one.
    let relaunches = upgradeScript.components(separatedBy: "open -a \"$APP\"").count - 1
    T.equal(relaunches, 2, "relaunched after the upgrade and after an early exit")
    T.expect(upgradeScript.contains("open -b 'cloud.facets.flow-bar'"),
             "falls back to the bundle id if the path moved")
}

T.test("it waits for the old app to exit") {
    // flow-bar quits itself so brew's AppleScript `quit` has nothing to do,
    // which is what keeps the upgrade off the Automation grant. Racing it would
    // put that back.
    T.expect(upgradeScript.contains("pgrep -f 'flow-bar.app/Contents/MacOS/flow-bar'"),
             "polls for the old process")
    T.expect(upgradeScript.contains("-lt 30"), "with a bounded wait, not forever")
}

T.test("it sets a PATH, because a GUI parent gives it almost none") {
    T.expect(upgradeScript.contains("PATH=/opt/homebrew/bin:/usr/local/bin"), "homebrew on PATH")
    T.expect(upgradeScript.contains("command -v brew"), "and checks brew is really there")
}

T.test("paths are quoted, so a space or apostrophe can't break the script") {
    let s = BrewUpgrade.script(
        appPath: "/Users/o'brien/My Apps/flow-bar.app",
        bundleID: "cloud.facets.flow-bar",
        logPath: "/Users/o'brien/Library/Logs/up.log",
        markerPath: "/Users/o'brien/Library/Application Support/flow-bar/last-upgrade",
        processMatch: "flow-bar")
    // "Application Support" always has a space; an apostrophe in a home
    // directory name is unusual but entirely legal.
    T.expect(s.contains("'/Users/o'\\''brien/My Apps/flow-bar.app'"), "apostrophe escaped")
    T.expect(s.contains("'/Users/o'\\''brien/Library/Application Support/flow-bar/last-upgrade'"),
             "space-bearing path quoted whole")
}

T.test("shellQuote") {
    T.equal(BrewUpgrade.shellQuote("plain"), "'plain'", "wraps")
    T.equal(BrewUpgrade.shellQuote("a b"), "'a b'", "space needs no escaping inside quotes")
    T.equal(BrewUpgrade.shellQuote("it's"), "'it'\\''s'", "apostrophe closes, escapes, reopens")
    T.equal(BrewUpgrade.shellQuote(""), "''", "empty")
    T.equal(BrewUpgrade.shellQuote("$(rm -rf /)"), "'$(rm -rf /)'",
            "single quotes make substitution inert")
}

T.test("the manual command matches what the script does") {
    // The copy-to-clipboard fallback must not drift from the automated path.
    T.expect(BrewUpgrade.manualCommand.contains("brew --repository pa/flow-bar"), "same tap")
    T.expect(BrewUpgrade.manualCommand.contains("pull --ff-only"), "same refresh")
    T.expect(BrewUpgrade.manualCommand.contains("brew upgrade --cask flow-bar"), "same upgrade")
}

T.test("the result marker round-trips") {
    T.equal(BrewUpgrade.Result(rawValue: "ok"), .ok, "ok")
    T.equal(BrewUpgrade.Result(rawValue: "failed"), .failed, "failed")
    T.expect(BrewUpgrade.Result(rawValue: "") == nil, "empty is not a verdict")
    T.expect(BrewUpgrade.Result(rawValue: "garbage") == nil, "nor is anything else")
}

print("\nClaudeHookConfig — splicing a file we don't own")

/// A settings.json shaped like the real one on this machine: other people's
/// hooks already installed, plus unrelated top-level keys.
func realWorldSettings() -> [String: Any] {
    [
        "agentPushNotifEnabled": true,
        "enabledPlugins": ["impeccable@impeccable": true],
        "hooks": [
            "Notification": [
                ["matcher": "",
                 "hooks": [["command": "~/.codeisland/codeisland-hook.sh",
                            "timeout": 86400, "type": "command"]]],
            ],
            "PermissionRequest": [
                ["hooks": [["command": "/Users/p/.orca/agent-hooks/claude-hook.sh",
                            "timeout": 10, "type": "command"]]],
            ],
        ],
    ]
}

T.test("install appends and leaves everything else untouched") {
    let before = realWorldSettings()
    let after = ClaudeHookConfig.install(into: before, scriptPath: "/tmp/hook.sh")

    // Unrelated top-level keys survive.
    T.equal(after["agentPushNotifEnabled"] as? Bool, true, "unrelated key kept")
    T.expect(after["enabledPlugins"] != nil, "plugins kept")

    let hooks = after["hooks"] as? [String: Any] ?? [:]
    // Somebody else's event, entirely untouched.
    T.expect(hooks["PermissionRequest"] != nil, "orca's PermissionRequest hook kept")

    let entries = ClaudeHookConfig.entries(in: after)
    T.equal(entries.count, 2, "CodeIsland's entry plus ours")
    T.expect(!ClaudeHookConfig.isOurs(entries[0]), "theirs is first and not ours")
    T.expect(ClaudeHookConfig.isOurs(entries[1]), "ours is appended last")
    T.expect(ClaudeHookConfig.isInstalled(in: after), "reported installed")
}

T.test("installing twice does not stack duplicates") {
    var s = ClaudeHookConfig.install(into: realWorldSettings(), scriptPath: "/tmp/a.sh")
    s = ClaudeHookConfig.install(into: s, scriptPath: "/tmp/b.sh")
    let ours = ClaudeHookConfig.entries(in: s).filter { ClaudeHookConfig.isOurs($0) }
    T.equal(ours.count, 1, "still exactly one of ours")
    // ...and the second install won, so a moved script path is repaired.
    let cmd = ((ours[0]["hooks"] as? [Any])?.first as? [String: Any])?["command"] as? String
    T.expect(cmd?.contains("/tmp/b.sh") == true, "path updated to the newer one")
    T.equal(ClaudeHookConfig.entries(in: s).count, 2, "CodeIsland's still there too")
}

T.test("remove takes only ours") {
    let installed = ClaudeHookConfig.install(into: realWorldSettings(), scriptPath: "/tmp/hook.sh")
    let after = ClaudeHookConfig.remove(from: installed)
    let entries = ClaudeHookConfig.entries(in: after)
    T.equal(entries.count, 1, "one entry left")
    T.expect(!ClaudeHookConfig.isOurs(entries[0]), "and it is CodeIsland's")
    T.expect(!ClaudeHookConfig.isInstalled(in: after), "no longer installed")
    T.expect((after["hooks"] as? [String: Any])?["PermissionRequest"] != nil, "orca's kept")
    T.equal(after["agentPushNotifEnabled"] as? Bool, true, "unrelated keys kept")
}

T.test("remove is a no-op when we were never installed") {
    let before = realWorldSettings()
    let after = ClaudeHookConfig.remove(from: before)
    T.equal(ClaudeHookConfig.entries(in: after).count, 1, "their entry untouched")
    T.expect((after["hooks"] as? [String: Any])?["PermissionRequest"] != nil, "and theirs")
}

T.test("uninstalling from a file where we were the only hook leaves no debris") {
    let empty: [String: Any] = ["theme": "dark"]
    let installed = ClaudeHookConfig.install(into: empty, scriptPath: "/tmp/hook.sh")
    T.expect(installed["hooks"] != nil, "hooks created")
    let after = ClaudeHookConfig.remove(from: installed)
    T.expect(after["hooks"] == nil, "empty hooks key pruned, not left as {}")
    T.equal(after["theme"] as? String, "dark", "their settings survive")
}

T.test("install works on an empty or absent settings file") {
    let after = ClaudeHookConfig.install(into: [:], scriptPath: "/tmp/hook.sh")
    T.expect(ClaudeHookConfig.isInstalled(in: after), "installed from nothing")
    T.equal(ClaudeHookConfig.entries(in: after).count, 1, "exactly one entry")
}

T.test("the matcher covers blocking notifications and nothing else") {
    let types = ClaudeHookConfig.matcher.split(separator: "|").map(String.init)
    // These mean "stopped, wants a human".
    for t in ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"] {
        T.expect(types.contains(t), "matches \(t)")
    }
    // These are informational and must never raise an alert.
    for t in ["auth_success", "agent_completed", "quota_auto_resume_fired"] {
        T.expect(!types.contains(t), "ignores \(t)")
    }
}

T.test("a foreign entry that merely mentions flow-bar is not ours") {
    var s = realWorldSettings()
    var hooks = s["hooks"] as! [String: Any]
    hooks["Notification"] = [
        ["matcher": "", "hooks": [["command": "echo flow-bar", "type": "command"]]],
    ]
    s["hooks"] = hooks
    // Ownership is the marker comment, not a substring of the path — otherwise
    // uninstalling flow-bar would delete somebody else's hook.
    T.expect(!ClaudeHookConfig.isInstalled(in: s), "not ours without the marker")
    T.equal(ClaudeHookConfig.entries(in: ClaudeHookConfig.remove(from: s)).count, 1, "kept")
}

print("\nSessionAlert")
T.test("decode a Notification payload") {
    let json = #"""
    {"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/w",
     "hook_event_name":"Notification","notification_type":"permission_prompt",
     "message":"Bash wants to run: npm test"}
    """#.data(using: .utf8)!
    let when = Date(timeIntervalSince1970: 1_000_000)
    let a = SessionAlert.decode(json, at: when)
    T.equal(a?.sessionID, "abc123", "session id")
    T.equal(a?.kind, "permission_prompt", "kind")
    // Claude Code's own wording beats anything we could invent.
    T.equal(a?.label, "Bash wants to run: npm test", "label prefers the message")
}
T.test("a payload with no session id is useless and rejected") {
    T.expect(SessionAlert.decode(Data(#"{"message":"hi"}"#.utf8), at: Date()) == nil, "no id")
    T.expect(SessionAlert.decode(Data("not json".utf8), at: Date()) == nil, "not json")
    T.expect(SessionAlert.decode(Data(#"{"session_id":""}"#.utf8), at: Date()) == nil, "empty id")
}
T.test("labels fall back per notification type when there is no message") {
    func label(_ kind: String) -> String {
        SessionAlert(sessionID: "s", kind: kind, message: "", at: Date()).label
    }
    T.equal(label("permission_prompt"), "needs approval", "permission")
    T.equal(label("idle_prompt"), "waiting for you", "idle")
    T.equal(label("agent_needs_input"), "needs input", "needs input")
    T.equal(label("something_new"), "waiting on you", "unknown kind still reads sensibly")
}

print("\nSessionLocator")
T.test("session ids are validated before becoming a path") {
    T.expect(SessionLocator.isValidSessionID("f3f17e0d-e93c-4459-9a1f-19f118824119"), "a real uuid")
    T.expect(!SessionLocator.isValidSessionID("../../../etc/passwd"), "no traversal")
    T.expect(!SessionLocator.isValidSessionID("short"), "too short")
    T.expect(!SessionLocator.isValidSessionID(""), "empty")
    T.expect(!SessionLocator.isValidSessionID("f3f17e0d/e93c"), "no separators")
}

T.test("a Codex rollout is matched on the id SUFFIX, not a substring") {
    // Codex names files rollout-<ISO timestamp>-<thread id>.jsonl, so the id is
    // the tail of the stem. Matching "contains" would let the timestamp digits
    // produce false hits.
    let id = "019e4172-04bb-7b62-b290-9ecd1e92a41c"
    T.expect(SessionLocator.isCodexTranscript(
        filename: "rollout-2026-05-19T23-44-11-\(id).jsonl", sessionID: id), "real rollout name")
    T.expect(!SessionLocator.isCodexTranscript(
        filename: "rollout-2026-05-19T23-44-11-\(id)-extra.jsonl", sessionID: id),
        "id must end the stem")
    T.expect(!SessionLocator.isCodexTranscript(filename: "\(id).jsonl", sessionID: id),
             "a Claude-style name is not a rollout")
    T.expect(!SessionLocator.isCodexTranscript(
        filename: "rollout-2026-05-19T23-44-11-\(id).jsonl.bak", sessionID: id), "wrong extension")
    T.expect(!SessionLocator.isCodexTranscript(
        filename: "rollout-2026-05-19-aaaaaaaa-0000-0000-0000-000000000000.jsonl", sessionID: id),
        "different thread")
}

print("\nparseSessionInfo")
T.test("session id and work dir come back without their annotations") {
    let text = """
    slug:          flow-bar-notch
    name:          Dynamic island surface for flow-bar
    project:       flow-bar
    status:        in-progress
    work_dir:      /Users/p/dev/projects/flow-bar  [known]
    session_id:            f3f17e0d-e93c-4459-9a1f-19f118824119  [live]
    session_started:       2026-09-15T20:50:04+05:30
    updates:
      - /Users/p/.flow/tasks/flow-bar-notch/updates/a.md
    kb:
      - /Users/p/.flow/kb/user.md
    """
    let info = FlowClient.parseSessionInfo(slug: "flow-bar-notch", text: text)
    T.equal(info.sessionID, "f3f17e0d-e93c-4459-9a1f-19f118824119", "session id, no [live]")
    T.equal(info.workDir, "/Users/p/dev/projects/flow-bar", "work dir, no [known]")
    T.expect(info.live, "live flag read from the annotation")
}
T.test("a bootstrapped-but-dead session is not live") {
    let info = FlowClient.parseSessionInfo(
        slug: "x", text: "session_id:            93ac39cb-8ae5-466a-92e3-54c4d6c16856\n")
    T.equal(info.sessionID, "93ac39cb-8ae5-466a-92e3-54c4d6c16856", "id still parsed")
    T.expect(!info.live, "no [live] annotation means not live")
}
T.test("an unbootstrapped task has no session") {
    T.expect(FlowClient.parseSessionInfo(slug: "x", text: "session_id:   (none)\n").sessionID == nil,
             "(none)")
    T.expect(FlowClient.parseSessionInfo(slug: "x", text: "status: backlog\n").sessionID == nil,
             "absent line")
}
T.test("indented lines never masquerade as fields") {
    // `updates:`/`kb:` items are indented `- <path>` lines; one of them
    // containing a colon must not be read as a top-level key.
    let info = FlowClient.parseSessionInfo(
        slug: "x", text: "updates:\n  - /tmp/session_id: not-a-field.md\nwork_dir: /tmp/w\n")
    T.equal(info.workDir, "/tmp/w", "real field still found")
    T.expect(info.sessionID == nil, "list item ignored")
}
T.test("a headless --auto run is identified as one") {
    // `flow do --auto` sessions are live and write transcripts, but have no tab
    // and cannot prompt — the watcher drops them rather than raising an alert
    // pointing at a terminal that does not exist.
    let running = FlowClient.parseSessionInfo(slug: "x", text: """
    session_id:            93ac39cb-8ae5-466a-92e3-54c4d6c16856  [live]
    auto_run:              running (pid 48213)
    """)
    T.expect(running.autoRunning, "running (pid …) is an active auto run")
    let finished = FlowClient.parseSessionInfo(
        slug: "x", text: "auto_run:              completed (2026-06-11T20:08:17+05:30)\n")
    T.equal(finished.autoRun, "completed", "state is the leading word only")
    T.expect(!finished.autoRunning, "a completed auto run no longer owns the task")
    T.expect(!FlowClient.parseSessionInfo(slug: "x", text: "status: in-progress\n").autoRunning,
             "a task that was never run headlessly has no auto run")
}
T.test("splitAnnotation") {
    T.equal(FlowClient.splitAnnotation("  /a/b  [known]").value, "/a/b", "value")
    T.equal(FlowClient.splitAnnotation("  /a/b  [known]").annotation, "known", "annotation")
    T.equal(FlowClient.splitAnnotation("  plain  ").value, "plain", "no annotation")
    T.equal(FlowClient.splitAnnotation("  plain  ").annotation, "", "empty annotation")
    // A path that legitimately ends in a bracket keeps its brackets as the
    // annotation — acceptable, because neither field can contain one.
    T.equal(FlowClient.splitAnnotation("").value, "", "empty input")
}

print("\nRelativeAge")
let ageBase = Date(timeIntervalSince1970: 1_000_000)
T.equal(RelativeAge.short(ageBase, now: ageBase), "0s", "just now")
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(45)), "45s", "seconds")
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(60)), "1m", "one minute")
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(3_599)), "59m", "under an hour")
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(7_200)), "2h", "hours")
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(172_800)), "2d", "days")
// Clock skew between the transcript's UTC stamp and local time must not render
// as a negative age.
T.equal(RelativeAge.short(ageBase, now: ageBase.addingTimeInterval(-30)), "0s", "future clamps to 0")

print("\nSessionAttention")
// Only "a human has to answer this" is reported. A finished turn is how every
// turn ends, so counting it made the icon and the list permanently full.
let turnEnd = Date(timeIntervalSince1970: 1_700_000_000)

T.expect(SessionAttention.isBlocked(.waitingOnYou(tool: "AskUserQuestion", since: turnEnd)),
         "a question Claude asked you blocks")
T.expect(SessionAttention.isBlocked(.waitingOnYou(tool: "ExitPlanMode", since: turnEnd)),
         "a plan waiting for approval blocks")
T.expect(SessionAttention.isBlocked(.waitingOnYou(tool: "permission_prompt", since: turnEnd)),
         "a permission prompt blocks")
// The route that keeps "Claude is waiting for my input" reportable without
// reporting every turn boundary: Claude Code decides, and says so via the hook.
T.expect(SessionAttention.isBlocked(.waitingOnYou(tool: "idle_prompt", since: turnEnd)),
         "a hook idle_prompt blocks — Claude itself said it is waiting")
T.expect(SessionAttention.isBlocked(.waitingOnYou(tool: "agent_needs_input", since: turnEnd)),
         "…as does agent_needs_input")

T.expect(!SessionAttention.isBlocked(.awaitingPrompt(since: turnEnd)),
         "a bare finished turn is NOT an alert")
T.expect(!SessionAttention.isBlocked(.awaitingPrompt(since: nil)), "…dated or not")
T.expect(!SessionAttention.isBlocked(.working(tool: "Bash", since: turnEnd)), "working")
T.expect(!SessionAttention.isBlocked(.thinking(since: turnEnd)), "thinking")
T.expect(!SessionAttention.isBlocked(.unknown), "unknown")

print("\nSessionRowLabel")
// Session rows lead with the slug — what you type and what `flow do` takes —
// so the name is demoted to a subtitle that has to earn its line.
T.equal(SessionRowLabel.secondary(
            slug: "flow-bar-attention",
            name: "flow-bar: opening permissions, session-alert coverage, slug-first labels"),
        "flow-bar: opening permissions, session-alert coverage, slug-first labels",
        "a real title earns its line")
T.expect(SessionRowLabel.secondary(slug: "scrut-evidence", name: "scrut-evidence") == nil,
         "a task named after its own slug adds nothing")
T.expect(SessionRowLabel.secondary(slug: "scrut-evidence", name: "Scrut Evidence") == nil,
         "…and punctuation/case are not information")
// flow names a run task "<playbook> run <run-slug>", which is the first line
// twice over — this is what keeps a playbook-run row at two lines.
T.expect(SessionRowLabel.secondary(
            slug: "ms-update--2026-09-16-06-41",
            name: "ms-update run ms-update--2026-09-16-06-41") == nil,
         "a playbook run's synthetic name is all slug")
T.expect(SessionRowLabel.secondary(slug: "x", name: "   ") == nil, "blank name")
T.equal(SessionRowLabel.secondary(slug: "frammer-eol-packages",
                                  name: "  Retire EoL packages  "),
        "Retire EoL packages", "subtitle is trimmed")
// One novel token is enough: the slug can carry most of the name and still
// leave something worth reading.
T.equal(SessionRowLabel.secondary(slug: "flow-bar", name: "flow-bar notch"),
        "flow-bar notch", "one new word is enough")

print("\ndoTaskArgs")
T.equal(FlowClient.doTaskArgs("flow-bar-attention"),
        ["do", "flow-bar-attention"],
        "a plain open passes no mode flag")
T.equal(FlowClient.doTaskArgs("flow-bar-attention", skipPermissions: true),
        ["do", "flow-bar-attention", "--dangerously-skip-permissions"],
        "⌥-click asks flow to skip permission prompts")

// MARK: - Palette

print("\nPaletteMatcher")

func pitem(_ title: String, subtitle: String? = nil, keywords: [String] = [],
           kind: PaletteKind = .task, rank: Int = 0) -> PaletteItem {
    PaletteItem(id: "\(kind.rawValue):\(title)", kind: kind, title: title,
                subtitle: subtitle, keywords: keywords,
                action: .openTask(title), rank: rank)
}
func mscore(_ q: String, _ item: PaletteItem) -> Int? {
    PaletteMatcher.match(query: q, item: item)?.score
}

// The ladder, best to worst. Written as one chain rather than five asserted
// constants: the absolute numbers are free to move, the ORDER is the contract.
do {
    let exact     = mscore("bar", pitem("bar"))
    let prefix    = mscore("bar", pitem("bar-chart"))
    let wordStart = mscore("bar", pitem("flow-bar"))
    let contains  = mscore("bar", pitem("flowbarx"))
    let fuzzy     = mscore("bar", pitem("b-a-r"))
    T.expect([exact, prefix, wordStart, contains, fuzzy].allSatisfy { $0 != nil },
             "every rung of the ladder matches")
    T.expect(exact! > prefix!, "exact beats prefix")
    T.expect(prefix! > wordStart!, "prefix beats a later word's prefix")
    T.expect(wordStart! > contains!, "a word start beats a mid-word substring")
    T.expect(contains! > fuzzy!, "a substring beats a scattered subsequence")
}

// Field weights sit above match quality: what you can SEE outranks what you
// can't. A fuzzy hit on the title beats an exact hit on an invisible keyword.
T.expect(mscore("bar", pitem("b-a-r"))! > mscore("bar", pitem("zzz", keywords: ["bar"]))!,
         "a title subsequence beats a keyword exact match")
T.expect(mscore("notch", pitem("zzz", subtitle: "notch"))!
             > mscore("notch", pitem("zzz", keywords: ["notch"]))!,
         "subtitle outranks keyword")

// Keywords are not displayed, so a fuzzy hit on one produces a row with
// nothing in it resembling what you typed. They match on substrings only.
T.expect(PaletteMatcher.match(query: "bar", item: pitem("zzz", keywords: ["banana-republic"])) == nil,
         "keywords do not fuzzy-match (b-a-r is in banana-republic)")
T.expect(mscore("republic", pitem("zzz", keywords: ["banana-republic"])) != nil,
         "…but a keyword substring still matches")

// A space is AND across fields — this is what makes "flow notch" work, where
// neither substring nor subsequence survives the gap.
T.expect(mscore("flow notch", pitem("flow-bar-notch")) != nil, "every token must hit")
T.expect(mscore("flow zzz", pitem("flow-bar-notch")) == nil, "one missed token fails the item")
T.expect(mscore("flow notch", pitem("flow-bar-notch"))! > mscore("flow", pitem("flow-bar-notch"))!,
         "two hits score above one")
T.expect(mscore("", pitem("flow-bar")) == nil, "an empty query matches nothing")
T.expect(mscore("flow-bar-notch-extra", pitem("flow-bar")) == nil, "query longer than the title")

// Highlights are offsets into the title, so the UI can bold the hit.
T.equal(PaletteMatcher.match(query: "notch", item: pitem("flow-bar-notch"))?.titleOffsets,
        [9, 10, 11, 12, 13], "title offsets mark the matched run")
T.equal(PaletteMatcher.match(query: "notch", item: pitem("zzz", keywords: ["notch"]))?.titleOffsets,
        [], "a keyword hit highlights nothing — there is nothing visible to mark")
T.equal(PaletteMatcher.match(query: "flow notch", item: pitem("flow-bar-notch"))?.titleOffsets,
        [0, 1, 2, 3, 9, 10, 11, 12, 13], "both tokens highlight, merged and sorted")

print("\nPaletteIndex")

let pTasks = [
    task("flow-bar-notch", name: "flow-bar: session alerts", status: "in-progress",
         priority: "medium", project: "flow-bar", live: true, tags: ["swift"]),
    task("tessera-app", name: "tessera-app", status: "in-progress", priority: "medium",
         project: "tessera", live: true),
    task("meymai-push-backlog", name: "Push the backlog", status: "in-progress",
         priority: "high", project: "meymai", stale: true),
    task("side-quest-docs", name: "Write the docs", status: "in-progress", priority: "low"),
    task("pa-homepage-copy", name: "Rewrite the copy", status: "backlog", priority: "low"),
    task("frammer-eol", name: "Retire EoL packages", status: "done", priority: "low"),
]
let pIndex = PaletteIndex.build(
    tasks: pTasks,
    projects: [Project(slug: "flow-bar", name: "flow-bar", priority: "high",
                       status: "active", total: 3, inProgress: 1, backlog: 0, done: 2,
                       updated: nil)],
    playbooks: [Playbook(slug: "ms-update", project: "meymai")],
    owners: [Owner(slug: "repo-keeper", status: "active", every: "3h",
                   nextTick: nil, nextTickRelative: "in 1h59m")],
    tags: [TagCount(tag: "swift", count: 2)],
    blocked: ["meymai-push-backlog"])

// The first row is what Enter hits, so an exact slug can never come second.
T.equal(pIndex.search("flow-bar-notch").first?.id, "task:flow-bar-notch",
        "an exact slug leads the results")
T.equal(pIndex.search("fbn").first?.id, "task:flow-bar-notch",
        "initials find the task — the whole point of ranking over contains()")
T.equal(pIndex.search("tessera").first?.id, "task:tessera-app", "a plain prefix")
T.equal(pIndex.search("swift").first?.id, "tag:swift",
        "a tag is findable by its bare name, without the #")

// Both found by running the index against real data, not by reasoning about it.
do {
    // "flow" prefix-matches the project `flow-bar` and the task
    // `flow-bar-notch` equally well; the project's title is merely shorter.
    // The row whose Enter actually opens something wins that argument.
    let r = pIndex.search("flow")
    T.equal(r.first?.kind, .task, "a task leads an equally-good project match")
    T.expect(r.flat.contains { $0.id == "project:flow-bar" }, "the project is still there")
    // …but the bias is far smaller than a rung, so a genuinely better match
    // still wins: an exact project name beats a task that merely starts with it.
    let exactly = PaletteIndex.build(
        tasks: [task("flow-bar-notch", status: "in-progress")],
        projects: [Project(slug: "flow-bar", name: "flow-bar", priority: "high",
                           status: "active", total: 1, inProgress: 1, backlog: 0,
                           done: 0, updated: nil)])
    T.equal(exactly.search("flow-bar").first?.kind, .project,
            "an exact match still outranks a task — the thumb is not a fist")
}

// A subtitle is a sentence, so fuzzy-matching it finds accidents. Real case:
// "palette" was pulling in a task named "…playbook parity, done lists, honest
// badges", which carries p-a-l-e-t-t-e scattered across three words.
do {
    let noise = pitem("zzz", subtitle: "playbook parity, done lists, honest badges")
    T.expect(PaletteMatcher.match(query: "palette", item: noise) == nil,
             "a subtitle does not fuzzy-match")
    T.expect(mscore("parity", noise) != nil, "…but a substring of it still does")
    T.expect(mscore("fbn", pitem("flow-bar-notch")) != nil,
             "the title keeps fuzzy matching — that is what initials need")
}

// Sections follow their best member, so the leading group is whichever kind
// won — a command can outrank every task and say so with its header.
do {
    let r = PaletteIndex.build(tasks: [task("review-needs-triage", status: "in-progress")])
        .search("needs")
    T.equal(r.sections.first?.title, "Commands", "the best match's kind leads")
    T.equal(r.first?.id, "cmd:inbox", "…and it is the first row")
}

// The cursor is an index into `flat`, so `flat` must be exactly what is drawn.
do {
    let r = pIndex.search("a")
    T.equal(r.flat.count, r.count, "flat and count agree")
    T.equal(r.flat.map { $0.id }, r.sections.flatMap { $0.items.map { $0.id } },
            "flat is the sections concatenated, in display order")
    T.expect(r.sections.allSatisfy { !$0.items.isEmpty }, "no empty section headers")
}

// Typing the word in your head when the icon is orange must land on the work,
// not on the section that lists it.
do {
    let r = pIndex.search("blocked")
    // Needs-you leads, and that is the field-weight rule keeping its promise
    // rather than an accident: its subtitle *says* "Blocked sessions", where
    // the task's only claim to the word is an invisible keyword. The explicable
    // row wins. The task is still right behind it, which it would not be
    // without that keyword — no field of a blocked task contains "blocked".
    T.equal(r.first?.id, "cmd:inbox", "the row that visibly says 'Blocked' leads")
    T.equal(r.sections.first { $0.title == "Tasks" }?.items.first?.id,
            "task:meymai-push-backlog", "and the blocked task is the top task")
    T.expect(PaletteMatcher.match(query: "blocked", item: pitem("meymai-push-backlog")) == nil,
             "…which nothing but the keyword could have achieved")
}

// Equal scores break toward what you can actually open.
do {
    let idx = PaletteIndex.build(tasks: [
        task("alpha-one", status: "done", priority: "medium"),
        task("alpha-two", status: "in-progress", priority: "medium", live: true),
    ])
    T.equal(idx.search("alpha").first?.id, "task:alpha-two",
            "a live session outranks a done task at the same score, alphabetical order be damned")
}

// Badges are what make the list readable without reading it — and they are the
// SAME marks the popover uses, so nothing has to be learned twice.
do {
    func badges(_ id: String) -> [PaletteBadge] {
        pIndex.items.first { $0.id == id }?.badges ?? []
    }
    T.equal(badges("task:flow-bar-notch"), [.live], "a live session shows a dot")
    T.expect(badges("task:meymai-push-backlog").contains(.blocked),
             "blocked outranks live — the hand, not the dot")
    T.expect(!badges("task:meymai-push-backlog").contains(.live),
             "…and replaces it, rather than sitting beside it")
    T.expect(badges("task:meymai-push-backlog").contains(.stale(nil)), "stale is carried over")
    T.equal(badges("task:pa-homepage-copy"), [], "backlog work is unremarkable")
    T.equal(badges("cmd:inbox"), [], "a command is not a session")

    // `flow do` focuses a running tab and returns before it builds a command
    // line, so --dangerously-skip-permissions never reaches the harness there.
    // The panel only offers it where it can do something.
    func item(_ id: String) -> PaletteItem? { pIndex.items.first { $0.id == id } }
    T.expect(item("task:flow-bar-notch")?.hasLiveSession == true,
             "a live task has a running session")
    T.expect(item("task:meymai-push-backlog")?.hasLiveSession == true,
             "…and so does a blocked one — blocked IS live, stopped to ask you something")
    T.expect(item("task:pa-homepage-copy")?.hasLiveSession == false,
             "a backlog task has no session, so skipping prompts means something")
    T.expect(item("cmd:settings")?.hasLiveSession == false, "a command has no session")

    // Order is what stops you first, then what is merely late.
    // A due badge needs a LABEL, not just a date — same rule as TaskRow, which
    // renders flow's own wording rather than formatting the date itself.
    let dated = FlowTask(slug: "x", name: "X", status: "in-progress", priority: "medium",
                         stale: true, waitingOn: "review", live: true,
                         dueInDays: -2, dueLabel: "overdue 2d")
    let busy = PaletteIndex.build(tasks: [dated], commands: []).items[0]
    T.equal(busy.badges.last, PaletteBadge.live,
            "the quiet live dot sits last, nearest the edge")
    T.equal(busy.badges.first, PaletteBadge.due("overdue 2d", overdue: true),
            "what is late comes first")
    T.expect(busy.badges.contains(PaletteBadge.waiting("review")),
             "the waiting note rides along for the tooltip")
    T.expect(PaletteIndex.build(tasks: [task("y", status: "in-progress", dueInDays: -2)],
                                commands: []).items[0].badges.isEmpty,
             "a due date with no label from flow shows nothing rather than a guess")
}

// Done and archived tasks stay searchable — they are just never on home.
T.expect(pIndex.search("frammer").first?.id == "task:frammer-eol", "a done task is findable")

// A half-filled index is a legal one: the reads land one at a time.
do {
    let empty = PaletteIndex.build()
    T.expect(!empty.search("needs").isEmpty, "commands alone still search")
    T.expect(empty.search("flow-bar-notch").isEmpty, "…and nothing is invented")
    T.expect(PaletteIndex.build(tasks: pTasks).search("tessera").first != nil,
             "tasks alone still search")
}

// A wide query cannot flood the list.
do {
    let many = (1...100).map { task("t-\($0)", status: "in-progress") }
    T.equal(PaletteIndex.build(tasks: many).search("t", limit: 5).count, 5, "limit is honoured")
}

print("\nPaletteRoute")

// The palette holds its own navigation, so a container's ↵ must resolve to a
// route rather than to a hand-off. Anything that returns nil here is something
// the panel genuinely cannot do alone.
T.equal(PaletteAction.openProject("flow-bar").route, .project("flow-bar"), "a project is entered")
T.equal(PaletteAction.openTag("swift").route, .tag("swift"), "a tag is entered")
T.equal(PaletteAction.openPlaybook("ms-update").route, .playbook("ms-update"), "a playbook is entered")
T.equal(PaletteAction.openOwner("repo-keeper").route, .owner("repo-keeper"), "an owner is entered")
T.expect(PaletteAction.openTask("x").route == nil,
         "a task's ↵ opens its tab — that is the app, not navigation")
T.expect(PaletteAction.newTask.route == nil, "intake needs a form the panel doesn't have")
T.expect(PaletteAction.settings.route == nil, "Settings is a window")
// Release notes are a document, and the palette already reads documents.
T.equal(PaletteAction.releaseNotes.route, .releaseNotes, "notes open in the palette")
T.expect(PaletteRoute.releaseNotes.isDetail, "…through the same reader a brief uses")

// Surfaced once, above everything, and only when there is something unread.
do {
    let announced = PaletteIndex.build(tasks: [task("a", status: "in-progress", live: true)],
                                       unreadRelease: "0.5.0").search("")
    T.equal(announced.sections.first?.title, "New in this version", "it leads the home list")
    T.equal(announced.first?.title, "What's new in v0.5.0", "and names the version")
    T.equal(announced.first?.action, .releaseNotes, "opening it reads them")

    let quiet = PaletteIndex.build(tasks: [task("a", status: "in-progress", live: true)]).search("")
    T.expect(quiet.sections.contains { $0.title == "New in this version" } == false,
             "nothing unread, nothing announced")
    // …but it is always reachable deliberately, banner or not.
    T.equal(PaletteIndex.build().search("@whats new").first?.id, "cmd:whats-new",
            "and it is a command you can just ask for")
    T.equal(PaletteIndex.build().search("@changelog").first?.id, "cmd:whats-new", "by that name too")
}

// The rail names panes; the palette names lists. The mapping is the only place
// those two vocabularies meet.
T.equal(PaletteAction.section("inbox").route, .list(.needsYou), "inbox is the needs-you list")
T.equal(PaletteAction.section("tasks").route, .list(.inProgress), "tasks is the in-progress list")
T.equal(PaletteAction.section("tags").route, .list(.tags), "tags maps straight through")
// Backlog is a filter on the Tasks pane in the popover, but a list of its own
// in the palette — which is all this vocabulary needs it to be.
T.equal(PaletteAction.section("backlog").route, .list(.backlog), "backlog is a list here")
T.equal(PaletteListKind.backlog.title, "Backlog", "and it names itself")
T.expect(PaletteCommands.all.contains { $0.id == "cmd:backlog" }, "reachable as a command")
T.equal(PaletteIndex.build().search("@backlog").first?.id, "cmd:backlog",
        "…and found by @, or by the words you would actually type")
T.equal(PaletteIndex.build().search("@todo").first?.id, "cmd:backlog", "todo")
T.equal(PaletteIndex.build().search("@later").first?.id, "cmd:backlog", "later")
T.expect(PaletteAction.section("dashboard").route == nil,
         "a grid of tiles is not a list — Overview still opens the popover")
T.expect(PaletteAction.section("search").route == nil, "the root is not a destination")
T.expect(PaletteAction.section("nonsense").route == nil, "an unknown section navigates nowhere")

// Tab expands a row; for a task that means its brief, which ↵ cannot mean.
do {
    let index = PaletteIndex.build(tasks: [task("flow-bar-notch", status: "in-progress")],
                                   projects: [Project(slug: "flow-bar", name: "flow-bar",
                                                      priority: "high", status: "active",
                                                      total: 1, inProgress: 1, backlog: 0,
                                                      done: 0, updated: nil)])
    let taskRow = index.items.first { $0.id == "task:flow-bar-notch" }!
    T.equal(taskRow.detailRoute, .task("flow-bar-notch"), "Tab on a task opens its brief")
    T.expect(!taskRow.entersOnPrimary, "…but ↵ still opens the tab")
    let projectRow = index.items.first { $0.id == "project:flow-bar" }!
    T.equal(projectRow.detailRoute, .project("flow-bar"), "a container expands into itself")
    T.expect(projectRow.entersOnPrimary, "…which is also what ↵ does to it")
}

T.equal(PaletteRoute.tag("swift").chip, "#swift", "a tag chip keeps its hash")
T.equal(PaletteRoute.list(.needsYou).chip, "Needs you", "a list chip reads as its title")
T.equal(PaletteRoute.task("x").chip, "x", "a task chip is its slug")
T.expect(PaletteRoute.task("x").isDetail, "a task renders a document")
T.expect(!PaletteRoute.project("x").isDetail, "a project renders a list")

print("\nPalette row facts")

// A row you can only FIND by a fact you cannot SEE looks arbitrary — so the
// project and tags that feed the keywords are carried for display too.
do {
    let item = PaletteIndex.build(
        tasks: [task("flow-bar-notch", name: "notch", status: "in-progress",
                     project: "flow-bar", tags: ["swift", "ui"])],
        commands: []).items[0]
    // The name is off the row — it crowded out the project and tags you scan
    // by — but it must still be findable, so it moves into the keywords.
    T.expect(item.subtitle == nil, "a task row carries no name")
    T.expect(item.keywords.contains("notch"), "…but the name is still searchable")
    T.equal(item.project, "flow-bar", "the project is shown, not just searched")
    T.equal(item.tags, ["swift", "ui"], "and so are the tags")
    T.expect(item.keywords.contains("flow-bar"), "…while still feeding the matcher")
    T.expect(item.keywords.contains("swift"), "…both of them")
}
do {
    let floating = PaletteIndex.build(
        tasks: [task("solo", status: "backlog")], commands: []).items[0]
    T.expect(floating.project == nil, "a floating task claims no project")
    T.expect(floating.tags.isEmpty, "and no tags")
}

// Opening a batch is an action like any other, so one place decides what a
// result does — the panel and the popover cannot drift on it.
T.expect(PaletteAction.openBatch(["a", "b"]).route == nil,
         "a batch acts on the world; it does not navigate")

print("\nJumpList")

// The list is placed by you and stays put — that stability is the feature.
do {
    var jump = JumpList()
    T.equal(jump.toggle("flow-bar-notch"), .added(1), "the first pin is ⌘1")
    T.equal(jump.toggle("tessera-app"), .added(2), "the second is ⌘2")
    T.equal(jump.number(of: "tessera-app"), 2, "and it keeps that number")
    T.equal(jump.slug(at: 1), "flow-bar-notch", "a number resolves to its task")
    T.expect(jump.slug(at: 3) == nil, "…and an unused one to nothing")
    T.expect(jump.contains("tessera-app"), "contains")

    // Pinning again unpins: one key, both directions.
    T.equal(jump.toggle("flow-bar-notch"), .removed, "toggling a pinned task removes it")
    T.equal(jump.number(of: "tessera-app"), 1,
            "removal renumbers what follows — better than a ⌘2 that does nothing")
    T.expect(!jump.contains("flow-bar-notch"), "and it is gone")
}

// Nine, because the keys run out — and a jump list you have to search is the
// search you already had.
do {
    var jump = JumpList()
    for i in 1...JumpList.capacity { T.equal(jump.toggle("t-\(i)"), .added(i), "fills to capacity") }
    T.expect(jump.isFull, "full")
    T.equal(jump.toggle("t-10"), .full, "the tenth is refused, not silently dropped")
    T.equal(jump.slugs.count, JumpList.capacity, "…and nothing was evicted to make room")
}

// A persisted list can carry junk from an older build or a hand edit.
T.equal(JumpList(["a", "b", "a"]).slugs, ["a", "b"], "duplicates collapse")
T.equal(JumpList((1...20).map { "t-\($0)" }).slugs.count, 9, "overflow is trimmed")

// A pinned task can be deleted out from under the list; a number that opens
// nothing is worse than one fewer number.
T.equal(JumpList(["a", "gone", "b"]).pruned(to: ["a", "b"]).slugs, ["a", "b"],
        "vanished tasks are pruned")
T.equal(JumpList(["a", "gone", "b"]).pruned(to: ["a", "b"]).number(of: "b"), 2, "and renumbered")

// On the home list it leads, in pin order — sorting it would destroy the
// muscle memory that makes ⌘2 worth having.
do {
    let index = PaletteIndex.build(
        tasks: [task("zeta", status: "in-progress", live: true),
                task("alpha", status: "in-progress")],
        jumpList: JumpList(["zeta", "alpha"]))
    let home = index.search("")
    T.equal(home.sections.first?.title, "Jump list", "it leads the home list")
    T.equal(home.sections.first?.items.map { $0.title }, ["zeta", "alpha"],
            "in pin order, not sorted")
    T.equal(home.sections.first?.items.first?.jumpNumber, 1, "carrying its number")
    T.expect(!home.sections.contains { $0.title == "Live sessions" },
             "a pinned task is not also listed below — it appears once")
    // A number travels with the task wherever it shows up, including a search.
    T.equal(index.search("alpha").first?.jumpNumber, 2, "the number shows in search results too")
}
T.expect(PaletteIndex.build(tasks: [task("a", status: "in-progress")]).search("")
            .sections.contains { $0.title == "Jump list" } == false,
         "no pins, no section")

print("\nPalette sigils")

// `@` scopes the list to commands rather than pushing anywhere, so backspacing
// it puts you back exactly where you were.
T.equal(PaletteQuery.parse("@").scope, .command, "a leading @ scopes to commands")
T.equal(PaletteQuery.parse("@set").text, "set", "…and is read off the query")
T.expect(PaletteQuery.parse("set").scope == nil, "no sigil, no scope")
T.expect(PaletteQuery.parse("user@example").scope == nil,
         "an @ inside a word is part of the word")
T.expect(PaletteQuery.parse("").scope == nil, "an empty query has no sigil")
T.equal(PaletteQuery.parse("@").chip, "Commands", "the scope names itself in the field")

do {
    // A bare sigil lists everything it scopes to.
    let all = pIndex.search("@")
    T.equal(all.sections.map { $0.title }, ["Commands"], "one group")
    T.equal(all.count, PaletteCommands.all.count, "every command, none of the tasks")
    T.expect(all.flat.allSatisfy { $0.kind == .command }, "nothing but commands")

    // …and typing after it filters only those.
    T.equal(pIndex.search("@set").first?.id, "cmd:settings", "the sigil's query still ranks")
    T.expect(pIndex.search("@flow-bar-notch").isEmpty,
             "a task cannot be found from inside the command scope")
    // Without the sigil the same query is dominated by the work, as it should be.
    T.equal(pIndex.search("flow-bar-notch").first?.kind, .task, "unscoped, the task wins")
}

// A sigil the index cannot honour is just a character. Inside a route there are
// no commands, so `@` has to search rather than blank the list.
do {
    let route = PaletteIndex.of(PaletteIndex.build(
        tasks: [task("a-task", status: "in-progress"), task("at-home", status: "backlog")],
        commands: []).items)
    T.equal(route.search("@at").first?.title, "at-home",
            "the sigil is dropped and its text searched")
    T.expect(route.search("@").isEmpty, "a bare @ with nothing to scope to shows nothing")
}

print("\nPalette listing")

// Inside a route an empty query means "all of it", not the root's home list.
do {
    let index = PaletteIndex.of(PaletteIndex.build(
        tasks: [task("b-task", status: "backlog"),
                task("a-task", status: "in-progress", live: true)],
        commands: []).items)
    let r = index.listing(title: "Tasks")
    T.equal(r.sections.map { $0.title }, ["Tasks"], "one group, named by the route")
    T.equal(r.flat.map { $0.title }, ["a-task", "b-task"],
            "live work first, not alphabetical")
    T.expect(!r.flat.contains { $0.kind == .command }, "no commands inside a route")
    // …and typing still ranks, on the route's rows only.
    T.equal(index.search("b-task").first?.title, "b-task", "the field filters the route")
    T.expect(index.search("settings").isEmpty, "the root's commands are not reachable from here")
}

// A playbook run is a task: its row opens a tab like any other.
do {
    let items = PaletteIndex.runItems([
        PlaybookRun(slug: "ms-update--2026-09-16-06-41", status: "done", playbook: "ms-update"),
        PlaybookRun(slug: "ms-update--2026-09-18-11-02", status: "in-progress", playbook: "ms-update"),
    ])
    T.equal(items.first?.action, .openTask("ms-update--2026-09-16-06-41"), "a run opens its tab")
    T.equal(PaletteIndex.of(items).listing(title: "Runs").flat.first?.title,
            "ms-update--2026-09-18-11-02", "a running run leads")
    // A run belongs to its playbook the way a task belongs to a project.
    T.expect(items.first?.subtitle == nil, "a run row carries no name either")
    T.equal(items.first?.project, "ms-update", "it reads with the same folder glyph")
}

print("\nDocumentSearch")

let briefText = """
Search-first popover

Why
Search is what the app is actually for — you open it to get to one task.
The rail-first root makes you pick a section before you can look for anything.

Done when
⌥⌘F lands on a search root with the field focused.
One query ranks across tasks, projects and commands.
The matcher is covered in the harness.
"""

/// The characters a query lights up, as text — the thing the eye will see.
func lit(_ query: String, _ text: String) -> [String] {
    let offsets = DocumentSearch.matchOffsets(query, in: text)
    let chars = Array(text)
    return DocumentSearch.runs(offsets).map { String(chars[$0.lowerBound..<$0.upperBound]) }
}

// A find lights up what you typed, where it is.
T.equal(lit("rail", briefText), ["rail"], "the word, highlighted in place")
T.equal(lit("SEARCH", briefText).count, 3, "case doesn't matter; every occurrence lights")
T.expect(lit("search", briefText).allSatisfy { $0.lowercased() == "search" },
         "…and only the word itself")

// Fuzzy, but only when the match is compact — the rule that makes a
// subsequence honest in prose.
T.equal(lit("matchr", briefText), ["matcher"], "a near-miss still finds the word it meant")
T.expect(lit("scrap", briefText).isEmpty, "letters strewn across a sentence are not a match")
// The measured case that forced the limit down: at 3n, "rail" matched
// "Ranking is a ladder" across fourteen characters.
T.expect(lit("rail", "Ranking is a ladder with field weights on top.").isEmpty,
         "a match spread across a sentence is noise, not a near-miss")
T.equal(DocumentSearch.spanLimit(for: "abc"), 7, "the span a 3-char query may stretch")

// Two words narrow the document: both must be on one line.
T.expect(!DocumentSearch.matchOffsets("query ranks", in: briefText).isEmpty, "AND within a line")
T.expect(DocumentSearch.matchOffsets("query harness", in: briefText).isEmpty,
         "two words from different lines are not a match")

// Runs, not letters — one highlight per word is what a text system wants.
T.equal(DocumentSearch.runs([2, 3, 4, 9, 10]), [2..<5, 9..<11], "far-apart offsets stay separate")
// A fuzzy match has holes by definition; leaving one letter dark in the middle
// of a word reads as a rendering bug, so small gaps are filled.
T.equal(DocumentSearch.runs([0, 1, 2, 3, 4, 6]), [0..<7], "a one-letter hole is filled")
T.equal(DocumentSearch.runs([0, 4], mergingGapsUpTo: 0), [0..<1, 4..<5], "…unless told not to")
T.equal(DocumentSearch.runs([]), [], "nothing to fold")
T.equal(DocumentSearch.runs([7]), [7..<8], "a single character is a run of one")

// Offsets are absolute across the whole document, including past a blank line.
do {
    let text = "alpha\n\nbeta alpha"
    T.equal(DocumentSearch.matchOffsets("alpha", in: text), [0, 1, 2, 3, 4, 12, 13, 14, 15, 16],
            "every occurrence, counted from the start of the document")
    T.equal(lit("alpha", text), ["alpha", "alpha"], "…and each lights up whole")
}

// CRLF is one Character in Swift, so line walking must not double-count it.
T.equal(DocumentSearch.matchOffsets("beta", in: "alpha\r\nbeta"), [6, 7, 8, 9],
        "offsets survive CRLF line endings")

T.expect(DocumentSearch.matchOffsets("   ", in: briefText).isEmpty, "a blank query finds nothing")
T.expect(DocumentSearch.matches("focused", in: briefText), "matches() is true when there is something to find")
T.expect(!DocumentSearch.matches("zzzz", in: briefText), "and false when there is not")

print("\nSDKFreshness")

// The measured case that forced this: macOS 27 with no macOS 27 SDK anywhere on
// the machine. The old check asked only "is the build behind the OS?" and
// nagged forever, because the rebuild it asked for produces the same binary.
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "26.5", availableSDK: "26.5", osMajor: 27),
         "no nudge when no newer SDK exists to rebuild against")
T.expect(SDKFreshness.shouldRebuild(buildSDK: "26.5", availableSDK: "27.0", osMajor: 27),
         "…and a nudge once the SDK lands, which is when it can be acted on")

// Both halves must hold.
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "26.5", availableSDK: "26.5", osMajor: 26),
         "a current build is not behind anything")
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "26.5", availableSDK: "27.0", osMajor: 26),
         "a newer SDK than the OS is not a reason to rebuild — nothing renders wrongly")
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "27.0", availableSDK: "27.0", osMajor: 26),
         "built ahead of the OS is fine")

// Unknowns mean silence: someone with no toolchain cannot act on it.
T.expect(!SDKFreshness.shouldRebuild(buildSDK: nil, availableSDK: "27.0", osMajor: 27),
         "an unstamped build says nothing")
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "26.5", availableSDK: nil, osMajor: 27),
         "no toolchain, no nudge")
T.expect(!SDKFreshness.shouldRebuild(buildSDK: "unknown", availableSDK: "27.0", osMajor: 27),
         "an unparseable stamp says nothing")

T.equal(SDKFreshness.major("26.5"), 26, "major")
T.equal(SDKFreshness.major("27"), 27, "major with no minor")
T.expect(SDKFreshness.major(nil) == nil, "nil")
T.expect(SDKFreshness.major("") == nil, "empty")

print("\nReleaseNotes")

let changelogFixture = """
# Changelog

All notable changes to flow-bar, newest first. The top section is published as
the GitHub release notes when a version is tagged.

## v0.5.0 — 2026-09-20

A second way in: ⌥Space opens a palette.

### Added

- A centered command palette.
- A jump list.

## v0.4.3 — 2026-09-17

### Fixed

- The session that lit the icon no longer vanishes.
"""

do {
    let top = ReleaseNotes.top(of: changelogFixture)
    T.equal(top?.version, "0.5.0", "the newest section, without its v")
    T.equal(top?.heading, "v0.5.0 — 2026-09-20", "the heading as written")
    T.expect(top?.body.hasPrefix("A second way in") == true, "body starts after the heading")
    T.expect(top?.body.contains("A jump list.") == true, "…and runs to the end of the section")
    T.expect(top?.body.contains("v0.4.3") == false, "…but not into the next one")
    // `### Added` is a subsection of a release; treating it as a section would
    // cut every entry into fragments.
    T.expect(top?.body.contains("### Added") == true, "sub-headings stay inside their release")
    T.equal(ReleaseNotes.sections(of: changelogFixture).count, 2, "one section per release")
}

T.equal(ReleaseNotes.section(version: "0.4.3", in: changelogFixture)?.heading,
        "v0.4.3 — 2026-09-17", "an older version is still findable")
T.equal(ReleaseNotes.section(version: "v0.4.3", in: changelogFixture)?.version, "0.4.3",
        "a tag-style version resolves too")
T.expect(ReleaseNotes.section(version: "9.9.9", in: changelogFixture) == nil,
        "a version the changelog never carried")
T.expect(ReleaseNotes.top(of: "# Changelog\n\nNothing yet.") == nil, "no releases, no section")
T.expect(ReleaseNotes.top(of: "") == nil, "an empty changelog")

// What gets rendered: the heading becomes the document's title.
T.expect(ReleaseNotes.top(of: changelogFixture)?.markdown.hasPrefix("# v0.5.0 — 2026-09-20") == true,
         "the section renders with its heading on top")

print("\nReleaseLinks")

// The tag format is shared by the cask's tarball URL, the git tag and this
// link. All three must agree, and the only symptom of disagreement is a 404
// nobody sees in a test run.
T.equal(ReleaseLinks.url(forVersion: "0.5.0").absoluteString,
        "https://github.com/pa/flow-bar/releases/tag/v0.5.0", "a version links to its tag")
T.equal(ReleaseLinks.url(forVersion: "v0.5.0").absoluteString,
        "https://github.com/pa/flow-bar/releases/tag/v0.5.0", "…and is not double-v'd")
T.equal(ReleaseLinks.url(forVersion: " 0.5.0 ").absoluteString,
        "https://github.com/pa/flow-bar/releases/tag/v0.5.0", "whitespace is trimmed")
// A local build's tag has never existed, so it goes somewhere that does.
T.equal(ReleaseLinks.url(forVersion: "0.0.0-dev").absoluteString,
        "https://github.com/pa/flow-bar/releases", "a dev build goes to the index")
T.equal(ReleaseLinks.url(forVersion: "").absoluteString,
        "https://github.com/pa/flow-bar/releases", "and so does an unknown version")

print("\nPaletteGeometry")

// A 1440x900 screen with the menubar taken out.
let screenA = CGRect(x: 0, y: 0, width: 1440, height: 875)
// A second display to the LEFT and taller — the arrangement that catches
// placement code which quietly assumes the origin is (0, 0).
let screenB = CGRect(x: -2560, y: -200, width: 2560, height: 1415)

do {
    let f = PaletteGeometry.frame(in: screenA, width: 700, height: 320)
    T.equal(f.midX, screenA.midX, "centred horizontally")
    T.equal(f.maxY, PaletteGeometry.topEdge(in: screenA), "top edge is the anchor")
    T.expect(f.maxY < screenA.maxY, "sits below the top of the screen")
    T.expect(f.maxY > screenA.midY, "…and above the middle of it")

    let g = PaletteGeometry.frame(in: screenB, width: 700, height: 320)
    T.equal(g.midX, screenB.midX, "centred on a screen with a negative origin")
    T.expect(g.minY > screenB.minY, "stays on that screen")
}

// Growing must not move the field out from under the cursor.
do {
    let top = PaletteGeometry.topEdge(in: screenA)
    let small = PaletteGeometry.frame(in: screenA, width: 700, height: 200)
    let grown = PaletteGeometry.resized(small, toHeight: 500, topEdge: top)
    T.equal(grown.maxY, small.maxY, "the top edge does not move when the list grows")
    T.equal(grown.height, 500, "…it grows downward")
    T.equal(grown.origin.x, small.origin.x, "and never sideways")
    let shrunk = PaletteGeometry.resized(grown, toHeight: 140, topEdge: top)
    T.equal(shrunk.maxY, small.maxY, "nor when it shrinks")
}

// A panel narrower than the screen it is on, and never taller than one.
T.equal(PaletteGeometry.frame(in: CGRect(x: 0, y: 0, width: 500, height: 400),
                              width: 700, height: 200).width,
        500, "a wide panel is capped by a narrow screen")
T.equal(PaletteGeometry.clampHeight(40), 120, "a near-empty list still has a body")
T.equal(PaletteGeometry.clampHeight(9000), 640, "and a long one stops short of the screen")
T.equal(PaletteGeometry.clampHeight(312.4), 312, "heights land on whole pixels")

print("\nPalette home list")

// Home answers "what am I in the middle of" — in the order you need it.
do {
    let r = pIndex.search("")
    T.equal(r.sections.map { $0.title }, ["Needs you", "Live sessions", "In progress", "Commands"],
            "blocked first, then live, then the rest, then commands")
    T.equal(r.sections[0].items.map { $0.title }, ["meymai-push-backlog"], "what needs you")
    T.equal(r.sections[1].items.map { $0.title }, ["flow-bar-notch", "tessera-app"], "live sessions")
    T.equal(r.sections[2].items.map { $0.title }, ["side-quest-docs"],
            "in-progress work with no live session still shows, below the live ones")
    // A blocked task is also live and also in-progress; it appears once.
    T.equal(r.flat.filter { $0.id == "task:meymai-push-backlog" }.count, 1,
            "a task appears once, in the most urgent group that claims it")
    let homeSlugs = Set(r.flat.map { $0.title })
    T.expect(!homeSlugs.contains("pa-homepage-copy"), "backlog is not on home")
    T.expect(!homeSlugs.contains("frammer-eol"), "done is not on home")
    T.equal(r.highlights.count, 0, "nothing is highlighted before you type")
}

T.equal(pIndex.search("   ").sections.map { $0.title }, pIndex.search("").sections.map { $0.title },
        "a whitespace-only query is still home")

// With nothing running, home is just the commands — never an empty panel.
do {
    let quiet = PaletteIndex.build(tasks: [task("x", status: "backlog")]).search("")
    T.equal(quiet.sections.map { $0.title }, ["Commands"], "an idle home still offers the commands")
}

// The praxis backend's own logic (PraxisClientTests.swift) — a function rather
// than top-level code, because only this file may carry top-level statements.
runPraxisClientTests()
runPraxisTranscriptTests()

T.summarize()
