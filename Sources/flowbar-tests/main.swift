import FlowBarCore
import Foundation

// Unit tests for the pure FlowBarCore logic. Run: swift run flowbar-tests

func task(_ slug: String, name: String = "", status: String = "in-progress",
          priority: String = "medium", project: String? = nil, stale: Bool? = nil,
          live: Bool? = nil, waitingOn: String? = nil, dueInDays: Int? = nil,
          tags: [String]? = nil, updated: String? = nil) -> FlowTask {
    FlowTask(slug: slug, name: name, status: status, priority: priority,
             project: project, stale: stale, waitingOn: waitingOn, live: live,
             updated: updated, tags: tags, dueInDays: dueInDays)
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

T.summarize()
