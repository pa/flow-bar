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
    T.equal(sorted.map(\.title), ["b", "c", "a"], "earliest first")
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
    T.equal([older, newer].group(now: now).completed.map(\.title), ["newer", "older"],
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
    let ids = [done, live].group(now: now).flattened().map(\.id)
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

T.summarize()
