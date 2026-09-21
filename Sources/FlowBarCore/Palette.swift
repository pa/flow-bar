import CoreGraphics
import Foundation

/// The search-first root: one query ranked across every entity flow knows
/// about, plus the app's own commands.
///
/// **Why this is a core type and not a view.** The popover's old search was
/// `filtered(by:)` — a substring test, scoped to whichever section you had
/// already picked. That scoping was doing real disambiguation work, so
/// dropping it in favour of one global list only works if the *ranking* is
/// good enough to replace it. Ranking is pure string logic, so it lives here
/// where `flowbar-tests` can hold it to an ordering contract, rather than in a
/// view where the only way to check it is to squint at a running app.
///
/// Nothing in this file imports AppKit or SwiftUI, and nothing here runs a
/// `flow` command. It takes already-decoded models and returns a list.

// MARK: - Kinds

/// What a result is. Also the grouping used for section headers.
public enum PaletteKind: String, Sendable, CaseIterable {
    case task, project, playbook, owner, tag, reminder, command

    /// Header shown above this kind's group.
    public var sectionTitle: String {
        switch self {
        case .task: return "Tasks"
        case .project: return "Projects"
        case .playbook: return "Playbooks"
        case .owner: return "Owners"
        case .tag: return "Tags"
        case .reminder: return "Reminders"
        case .command: return "Commands"
        }
    }

    /// A small thumb on the scale, added once per item.
    ///
    /// Only ever reorders rows that matched *equally well*, because it is far
    /// smaller than one rung of the match ladder (100+). Within a rung, the row
    /// you can act on directly wins: a task's Enter runs `flow do`, which is
    /// what the app is for, while every other row is navigation. Found on real
    /// data — typing "flow" put the project `flow-bar` above the task
    /// `flow-bar-notch`, purely because the project's title is six characters
    /// shorter, and the shorter-is-better rule had nothing arguing back.
    var bias: Int {
        switch self {
        case .task: return 30
        case .command: return -10   // always reachable by its own name
        default: return 0
        }
    }

    /// Tie-break order when two results score identically. Entities outrank
    /// commands: a command is always reachable by its own name, whereas the
    /// task you were reaching for may share a word with one.
    var rank: Int {
        switch self {
        case .task: return 0
        case .project: return 1
        case .playbook: return 2
        case .owner: return 3
        case .tag: return 4
        case .reminder: return 5
        case .command: return 6
        }
    }
}

// MARK: - Actions

/// What selecting a result does. The app layer switches on this.
///
/// `section` carries the rail section's *raw value* rather than the app's
/// `Section` enum, because that enum lives in the app target and this one must
/// stay importable by the test harness.
public enum PaletteAction: Hashable, Sendable {
    case openTask(String)          // flow do <slug>
    /// `flow do <slug> --dangerously-skip-permissions`, asked for explicitly.
    ///
    /// Separate from `openTask` because a *control* cannot read a modifier: by
    /// the time a clicked button's action runs, whatever was held when the
    /// panel opened is long gone. ⌥↵ and ⌥-click still go through `openTask`,
    /// where the Store reads the live keyboard. Same reason the popover's
    /// right-click menu passes the answer explicitly.
    case openTaskSkippingPrompts(String)
    /// Open several tasks at once — the multi-select batch.
    case openBatch([String])
    /// The batch, with permission prompts skipped. A separate case for the same
    /// reason `openTaskSkippingPrompts` is one: a clicked control cannot read a
    /// modifier, because by the time its action runs whatever was held is gone.
    case openBatchSkippingPrompts([String])
    /// Put a string on the clipboard — a slug, a project name, a tag list.
    case copy(String)
    /// Put a task's whole brief and notes on the clipboard. Separate from
    /// `copy` because the text isn't loaded until someone asks for it.
    case copyBrief(String)
    case togglePin(String)
    case toggleBatch(String)
    case openProject(String)       // drill into the project's task list
    case openPlaybook(String)      // drill into the playbook's runs
    case openOwner(String)
    case openTag(String)
    case openReminder(UUID)
    case section(String)           // Section.rawValue
    case newTask
    case newReminder
    /// Read this build's release notes, in the palette.
    case releaseNotes
    case refresh
    case settings
}

// MARK: - Query

/// A typed query, after its leading sigil has been read off.
///
/// **A sigil scopes; it does not navigate.** `@` narrows the same list to
/// commands rather than pushing a route, so backspacing it puts you back
/// exactly where you were — which is the whole reason to reach for a character
/// instead of a key. The chip in the field is there so a scoped list never
/// looks like a list that has mysteriously lost most of its rows.
public struct PaletteQuery: Equatable, Sendable {
    /// The kind the query is narrowed to, or nil for everything.
    public var scope: PaletteKind?
    /// What to actually match, with the sigil removed.
    public var text: String

    public init(scope: PaletteKind? = nil, text: String) {
        self.scope = scope
        self.text = text
    }

    /// Sigils, and what they narrow to.
    ///
    /// Every sigil is a character you can no longer type at the start of a
    /// search, so they are added one at a time and only where the thing they
    /// reach is otherwise hard to find. `@` earns it because commands have to be
    /// known by name before they can be typed. `#` earns it because it is
    /// already how a tag is written everywhere else in the app — on a row, in a
    /// brief's pills — so it is the character a hand reaches for anyway, and
    /// unscoped it merely matched the `#` in every tag title at once.
    public static let sigils: [Character: PaletteKind] = ["@": .command, "#": .tag]

    /// Read a leading sigil off a raw query. Only the first character counts:
    /// an `@` inside a word is part of the word.
    public static func parse(_ raw: String) -> PaletteQuery {
        guard let first = raw.first, let scope = sigils[first] else {
            return PaletteQuery(text: raw)
        }
        return PaletteQuery(scope: scope, text: String(raw.dropFirst()))
    }

    /// What the root field says it can do. It names the two sigils because
    /// nothing else can: a character you type first leaves no trace in the UI,
    /// and the footer no longer carries hints.
    public static let rootPlaceholder = "Search, @ for commands, # for tags"

    /// The chip shown in the field while this scope is on.
    public var chip: String? { scope?.sectionTitle }
}

// MARK: - Routes

/// A list the palette can push onto its own stack, rather than handing off.
public enum PaletteListKind: String, Hashable, Sendable, CaseIterable {
    case needsYou, inProgress, backlog, projects, playbooks, owners, tags, reminders

    /// The rail section's raw value this list corresponds to. The two
    /// vocabularies differ because the rail names *panes* and this names
    /// *lists* — "inbox" is a pane, "what needs you" is a list.
    public init?(sectionRawValue raw: String) {
        switch raw {
        case "inbox": self = .needsYou
        case "tasks": self = .inProgress
        // Not a rail pane of its own — the popover reaches it as the Tasks pane
        // with a filter — but it is a list, which is all this vocabulary needs.
        case "backlog": self = .backlog
        case "projects": self = .projects
        case "playbooks": self = .playbooks
        case "owners": self = .owners
        case "tags": self = .tags
        case "reminders": self = .reminders
        // "dashboard" is a grid of tiles, not a list — it has no palette form
        // and still opens the popover. "search" is the root we are already on.
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .inProgress: return "In progress"
        case .backlog: return "Backlog"
        case .projects: return "Projects"
        case .playbooks: return "Playbooks"
        case .owners: return "Owners"
        case .tags: return "Tags"
        case .reminders: return "Reminders"
        }
    }
}

/// Where the palette is. `nil`/empty stack is the root search.
///
/// **This is a stack, not a router.** The distinction matters because the
/// navigation deleted in `1e5cb4e` was a router — a graph of panes with focus
/// zones, where "where am I" and "where is the keyboard" were separate
/// questions with separate answers. Here there is one array: you push by
/// entering something, you pop with Esc, and the field never moves.
public enum PaletteRoute: Hashable, Sendable {
    case task(String)
    case releaseNotes
    case project(String)
    case playbook(String)
    case owner(String)
    case tag(String)
    case list(PaletteListKind)

    /// The chip shown in the search field.
    public var chip: String {
        switch self {
        case .task(let s), .project(let s), .playbook(let s), .owner(let s): return s
        case .tag(let t): return "#\(t)"
        case .list(let k): return k.title
        case .releaseNotes: return "What's new"
        }
    }

    /// What the field says while you are here.
    public var placeholder: String {
        switch self {
        case .task(let s): return "Search \(s)'s brief and notes…"
        case .project: return "Search this project's tasks…"
        case .playbook: return "Search this playbook's runs…"
        case .owner: return "Search what this owner owns…"
        case .tag: return "Search tagged tasks…"
        case .list(let k): return "Search \(k.title.lowercased())…"
        case .releaseNotes: return "Search the release notes…"
        }
    }

    /// Whether this route renders a document (brief + notes) rather than a list.
    /// Whether this route renders a document rather than a list.
    public var isDetail: Bool {
        switch self {
        case .task, .releaseNotes: return true
        default: return false
        }
    }
}

public extension PaletteAction {
    /// Where this action goes **inside** the palette, or nil when it acts on
    /// the world instead (opening a task's tab, the intake form, Settings).
    ///
    /// This is what stops the panel bouncing you into the popover for a look
    /// at a project: a container's primary action is to be entered, and the
    /// palette can hold it.
    var route: PaletteRoute? {
        switch self {
        case .openProject(let s): return .project(s)
        case .openPlaybook(let s): return .playbook(s)
        case .openOwner(let s): return .owner(s)
        case .openTag(let t): return .tag(t)
        case .section(let raw): return PaletteListKind(sectionRawValue: raw).map { .list($0) }
        case .releaseNotes: return .releaseNotes
        default: return nil
        }
    }
}

public extension PaletteItem {
    /// What Tab expands this row into.
    ///
    /// A task's primary action opens its terminal tab, which is the whole
    /// point of the app — so reading its brief has to be the *second* thing a
    /// row can do, not the first.
    var detailRoute: PaletteRoute? {
        switch action {
        case .openTask(let slug), .openTaskSkippingPrompts(let slug): return .task(slug)
        default: return action.route
        }
    }

    /// Whether ↵ navigates rather than doing something to the world.
    var entersOnPrimary: Bool { action.route != nil }

    /// Whether this row can be pinned to the jump list.
    ///
    /// Only a task, and only one `flow do` could act on: pinning a finished or
    /// archived task would hand it a number that opens nothing, and the next
    /// prune would silently take it away again.
    var isPinnable: Bool {
        guard kind == .task else { return false }
        if case .openTask = action {} else if case .openTaskSkippingPrompts = action {} else {
            return false
        }
        return !badges.contains(.done) && !badges.contains(.archived)
    }

    /// Whether a harness session is running for this row right now.
    ///
    /// Both marks mean a live process: `blocked` is a live session that has
    /// stopped to ask you something. This is what decides whether
    /// "skip permission prompts" is worth offering — `flow do` returns as soon
    /// as it focuses a running tab, so the flag never reaches the harness and
    /// the permission mode is whatever that process was started with.
    var hasLiveSession: Bool {
        badges.contains(.live) || badges.contains(.blocked)
    }
}

// MARK: - Item

/// What a row shows beyond its text.
///
/// **The same vocabulary as the popover's `TaskRow`**, because a task that is
/// stale in one window is stale in the other and nobody should have to learn
/// two sets of marks. Kept on the item rather than recomputed in the view: the
/// blocked case is only knowable at index time, when the session monitor is
/// sampled, and a view cannot go and ask.
public enum PaletteBadge: Hashable, Sendable {
    case blocked            // stopped, waiting on a human
    case live               // a harness session is running
    case due(String, overdue: Bool)
    case waiting(String?)   // waiting_on note
    case stale(Int?)        // days
    case done
    case archived

    /// Order on the row: what stops you first, then what is merely late.
    var rank: Int {
        switch self {
        case .blocked: return 0
        case .due:     return 1
        case .waiting: return 2
        case .stale:   return 3
        case .done:    return 4
        case .archived: return 5
        case .live:    return 6   // the quiet green dot sits last, nearest the edge
        }
    }
}

/// One row in the palette.
public struct PaletteItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: PaletteKind
    /// The line you read first. For anything flow-addressable this is the
    /// **slug** — what you type, what you search on, and the only string
    /// `flow do` takes (see `SessionRowLabel`).
    public var title: String
    /// The second line, when it says something the title doesn't.
    public var subtitle: String?
    /// Extra searchable strings that are not displayed: project, tags, status
    /// words, command aliases. Deliberately weaker than title/subtitle, and
    /// not fuzzy-matchable — see `PaletteMatcher`.
    public var keywords: [String]
    public var action: PaletteAction
    /// Tie-break weight within a kind; lower sorts first. Set by `build` from
    /// the source data (a live task above a done one), so equal-scoring
    /// results still come back in a useful order rather than alphabetically.
    public var rank: Int
    public var badges: [PaletteBadge]
    /// Its 1-based place in the jump list, if it is on it.
    public var jumpNumber: Int?
    /// Shown, not just searched: which project it belongs to and what it is
    /// tagged. Both are already in `keywords`, but a row you can only *find* by
    /// a fact you cannot *see* makes the result look arbitrary.
    public var project: String?
    public var tags: [String]

    public init(id: String, kind: PaletteKind, title: String, subtitle: String? = nil,
                keywords: [String] = [], action: PaletteAction, rank: Int = 0,
                badges: [PaletteBadge] = [], jumpNumber: Int? = nil,
                project: String? = nil, tags: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.action = action
        self.rank = rank
        self.badges = badges.sorted { $0.rank < $1.rank }
        self.jumpNumber = jumpNumber
        self.project = project
        self.tags = tags
    }
}

// MARK: - Results

/// A group of results under one header.
public struct PaletteSection: Identifiable, Hashable, Sendable {
    public var title: String
    public var items: [PaletteItem]
    public var id: String { title }

    public init(title: String, items: [PaletteItem]) {
        self.title = title
        self.items = items
    }
}

/// What a query produced.
///
/// **`flat` is exactly `sections` concatenated, in display order.** That is the
/// invariant the keyboard cursor depends on: it is an index into `flat`, and it
/// can only stay in sync with what the eye sees if the two are built from one
/// array. The last attempt at keyboard navigation in this app (deleted in
/// `1e5cb4e`) kept a cursor over a multi-pane tree with focus zones; this one
/// has no zones to be in the wrong one of.
public struct PaletteResults: Sendable, Equatable {
    public var sections: [PaletteSection]
    /// Per-item highlight offsets into `title`, keyed by item id. Empty for an
    /// item whose hit came from a keyword (nothing visible to underline).
    public var highlights: [String: [Int]]

    public init(sections: [PaletteSection], highlights: [String: [Int]] = [:]) {
        self.sections = sections
        self.highlights = highlights
    }

    /// Visual order, flattened — what the cursor indexes into.
    public var flat: [PaletteItem] { sections.flatMap(\.items) }
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
    public var count: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// The row Enter hits.
    public var first: PaletteItem? { flat.first }

    public func highlight(for item: PaletteItem) -> [Int] { highlights[item.id] ?? [] }
}

// MARK: - Matcher

/// Scores a query against one item.
///
/// The ladder, best to worst: exact, prefix, prefix of a later word, substring,
/// scattered subsequence. Field weights sit on top, so a *subsequence* hit on
/// the title still beats an *exact* hit on a keyword — the thing you typed at
/// is the thing you can see. Only the title matches fuzzily; a subtitle and a
/// keyword have to actually contain what you typed.
public enum PaletteMatcher {

    // Match quality.
    static let exactBonus = 500
    static let prefixBonus = 300
    static let wordPrefixBonus = 200
    static let containsBonus = 100

    // Which field the hit landed in.
    static let titleWeight = 1000
    static let subtitleWeight = 600
    static let keywordWeight = 300

    /// A scored hit.
    public struct Hit: Sendable, Equatable {
        public var score: Int
        /// Character offsets into the item's title to highlight. Empty when the
        /// hit came from a subtitle or keyword.
        public var titleOffsets: [Int]
    }

    /// Score `query` against `item`, or nil if it doesn't match.
    ///
    /// A whitespace-separated query is **all tokens must hit**, each scored
    /// against its own best field. That is what makes "flow notch" find
    /// `flow-bar-notch`: neither the substring nor the subsequence test would
    /// survive the space, but both halves hit the title independently.
    public static func match(query: String, item: PaletteItem) -> Hit? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(Array.init)
        guard !tokens.isEmpty else { return nil }

        var total = 0
        var offsets: [Int] = []
        for token in tokens {
            guard let best = bestField(token, item) else { return nil }
            total += best.score
            offsets.append(contentsOf: best.titleOffsets)
        }
        // Once per item, not per token — a two-word query must not double it.
        return Hit(score: total + item.kind.bias,
                   titleOffsets: Array(Set(offsets)).sorted())
    }

    /// The best-scoring field for one token.
    private static func bestField(_ token: [Character], _ item: PaletteItem) -> Hit? {
        var best: Hit?
        func consider(_ hit: Hit) {
            if best == nil || hit.score > best!.score { best = hit }
        }

        if let (s, offs) = fieldScore(token, item.title, allowSubsequence: true) {
            consider(Hit(score: titleWeight + s, titleOffsets: offs))
        }
        // Substrings only, like keywords. A title is a short dense slug, where
        // a scattered match is usually the one you meant; a subtitle is a
        // sentence, where it is usually an accident. Real data made the case:
        // searching "palette" returned a task whose name contains "…playbook
        // parity, done lists, honest badges", which has p-a-l-e-t-t-e strewn
        // through it and nothing to do with what was typed.
        if let sub = item.subtitle,
           let (s, _) = fieldScore(token, sub, allowSubsequence: false) {
            consider(Hit(score: subtitleWeight + s, titleOffsets: []))
        }
        // Keywords are invisible, so a fuzzy hit on one is unexplainable: the
        // row would appear with nothing in it resembling what you typed. They
        // match on substrings only.
        for kw in item.keywords {
            if let (s, _) = fieldScore(token, kw, allowSubsequence: false) {
                consider(Hit(score: keywordWeight + s, titleOffsets: []))
            }
        }
        return best
    }

    /// Score one whitespace-free token against one string.
    ///
    /// Public so document search runs the *same* ladder as the result list —
    /// one matcher in the app, not two that drift. `maxSpan` caps how far a
    /// scattered subsequence may stretch; see `fieldScore`.
    public static func score(_ token: String, in candidate: String,
                             allowSubsequence: Bool = true,
                             maxSpan: Int? = nil) -> (score: Int, offsets: [Int])? {
        fieldScore(Array(token.lowercased()), candidate,
                   allowSubsequence: allowSubsequence, maxSpan: maxSpan)
    }

    /// Score one token against one field.
    ///
    /// `maxSpan` is how many characters the match may stretch across. Nil means
    /// unlimited, which is right for a slug: `fbn` → `flow-bar-notch` spans ten
    /// characters for a three-character query and is exactly what you meant.
    /// Over prose it is not — the letters of any short word occur scattered
    /// through any paragraph — so a document search passes a limit and only
    /// compact matches survive.
    static func fieldScore(_ q: [Character], _ raw: String,
                           allowSubsequence: Bool,
                           maxSpan: Int? = nil) -> (score: Int, offsets: [Int])? {
        let c = Array(raw.lowercased())
        guard !q.isEmpty, q.count <= c.count else { return nil }

        if c == q { return (exactBonus, Array(0..<q.count)) }
        if c.starts(with: q) {
            return (prefixBonus + lengthPenalty(c.count, q.count), Array(0..<q.count))
        }
        // A hit at the start of a later word: "bar" in "flow-bar-notch".
        for start in wordStarts(c) where start > 0 {
            if matches(c, q, at: start) {
                return (wordPrefixBonus + lengthPenalty(c.count, q.count),
                        Array(start..<(start + q.count)))
            }
        }
        if let i = firstIndex(of: q, in: c) {
            return (containsBonus + earliness(i) + lengthPenalty(c.count, q.count),
                    Array(i..<(i + q.count)))
        }
        guard allowSubsequence, let offs = subsequence(q, in: c) else { return nil }
        if let maxSpan, let first = offs.first, let last = offs.last,
           last - first + 1 > maxSpan { return nil }
        return (subsequenceScore(offs, candidateCount: c.count, queryCount: q.count), offs)
    }

    // MARK: Scoring parts

    /// Earlier is better — a hit at the head of the string is the one you meant.
    static func earliness(_ index: Int) -> Int { max(0, 30 - index) }

    /// Shorter candidates win a tie: `flow-bar` before `flow-bar-notch-thing`
    /// when both merely contain the query. Capped so a long name can never be
    /// pushed below a worse match kind.
    static func lengthPenalty(_ candidateCount: Int, _ queryCount: Int) -> Int {
        -min(20, max(0, candidateCount - queryCount) / 3)
    }

    /// A scattered match is worth less the more gaps it has. `runs` counts
    /// contiguous stretches, so an unbroken run scores highest — at which point
    /// it would have been caught by the substring test anyway, which is why
    /// this tops out below `containsBonus`.
    static func subsequenceScore(_ offsets: [Int], candidateCount: Int, queryCount: Int) -> Int {
        var runs = 1
        for i in 1..<max(offsets.count, 1) where offsets[i] != offsets[i - 1] + 1 { runs += 1 }
        let contiguity = 12 * (queryCount - runs)
        return earliness(offsets[0]) + contiguity + lengthPenalty(candidateCount, queryCount)
    }

    // MARK: Primitives

    /// Index 0 plus every index that follows a non-alphanumeric character —
    /// so `-`, `_`, `:` and a space are all just word separators, matching how
    /// `SessionRowLabel` tokenises.
    static func wordStarts(_ c: [Character]) -> [Int] {
        var starts = [0]
        for i in 1..<max(c.count, 1) where !c[i - 1].isLetter && !c[i - 1].isNumber {
            if c[i].isLetter || c[i].isNumber { starts.append(i) }
        }
        return starts
    }

    static func matches(_ c: [Character], _ q: [Character], at start: Int) -> Bool {
        guard start + q.count <= c.count else { return false }
        for (k, ch) in q.enumerated() where c[start + k] != ch { return false }
        return true
    }

    static func firstIndex(of q: [Character], in c: [Character]) -> Int? {
        guard q.count <= c.count else { return nil }
        for start in 0...(c.count - q.count) where matches(c, q, at: start) { return start }
        return nil
    }

    /// Greedy left-to-right subsequence. Greedy is the right bias here: it
    /// packs the match as close to the head of the string as possible, which is
    /// what `earliness` then rewards.
    static func subsequence(_ q: [Character], in c: [Character]) -> [Int]? {
        var offsets: [Int] = []
        var qi = 0
        for (i, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] { offsets.append(i); qi += 1 }
        }
        return qi == q.count ? offsets : nil
    }
}

// MARK: - Commands

/// The app's own actions, searchable like anything else.
///
/// Aliases are the whole point of the `keywords` list here: "blocked" and
/// "waiting" have to find Needs-you, because those are the words in your head
/// when the icon is orange — the section's actual name is the one thing you
/// are least likely to type.
public enum PaletteCommands {
    public static let all: [PaletteItem] = [
        PaletteItem(id: "cmd:inbox", kind: .command, title: "Needs you",
                    subtitle: "Blocked sessions, questions and overdue work",
                    keywords: ["inbox", "blocked", "waiting", "attention", "questions", "overdue"],
                    action: .section("inbox"), rank: 0),
        PaletteItem(id: "cmd:tasks", kind: .command, title: "In progress",
                    subtitle: "Every task with a session",
                    keywords: ["tasks", "list", "current", "live"],
                    action: .section("tasks"), rank: 1),
        PaletteItem(id: "cmd:backlog", kind: .command, title: "Backlog",
                    subtitle: "Work that hasn't started",
                    keywords: ["todo", "later", "queue", "not started", "pending"],
                    action: .section("backlog"), rank: 2),
        PaletteItem(id: "cmd:dashboard", kind: .command, title: "Overview",
                    subtitle: "Metrics across all of flow",
                    keywords: ["dashboard", "metrics", "stats", "summary"],
                    action: .section("dashboard"), rank: 2),
        PaletteItem(id: "cmd:new-task", kind: .command, title: "New task…",
                    keywords: ["add", "create", "capture", "intake"],
                    action: .newTask, rank: 3),
        PaletteItem(id: "cmd:projects", kind: .command, title: "Projects",
                    keywords: ["project"], action: .section("projects"), rank: 4),
        PaletteItem(id: "cmd:playbooks", kind: .command, title: "Playbooks",
                    keywords: ["playbook", "runs", "run"],
                    action: .section("playbooks"), rank: 5),
        PaletteItem(id: "cmd:owners", kind: .command, title: "Owners",
                    keywords: ["owner", "autonomous", "tick"],
                    action: .section("owners"), rank: 6),
        PaletteItem(id: "cmd:tags", kind: .command, title: "Tags",
                    keywords: ["tag", "label"], action: .section("tags"), rank: 7),
        PaletteItem(id: "cmd:reminders", kind: .command, title: "Reminders",
                    keywords: ["reminder", "nudge", "notification", "bell"],
                    action: .section("reminders"), rank: 8),
        PaletteItem(id: "cmd:new-reminder", kind: .command, title: "New reminder…",
                    keywords: ["remind", "nudge", "add", "create"],
                    action: .newReminder, rank: 9),
        PaletteItem(id: "cmd:refresh", kind: .command, title: "Refresh",
                    keywords: ["reload", "sync"], action: .refresh, rank: 10),
        PaletteItem(id: "cmd:whats-new", kind: .command, title: "What's new",
                    subtitle: "Release notes for this version",
                    keywords: ["changelog", "release notes", "version", "updates", "changes"],
                    action: .releaseNotes, rank: 10),
        PaletteItem(id: "cmd:settings", kind: .command, title: "Settings…",
                    keywords: ["preferences", "config", "options", "alerts"],
                    action: .settings, rank: 11),
    ]
}

// MARK: - Index

/// Everything searchable, plus the list shown before you type anything.
public struct PaletteIndex: Sendable {
    /// Every searchable row, in no particular order — ranking is per-query.
    public var items: [PaletteItem]
    /// What an empty query shows.
    public var home: [PaletteSection]

    /// The jump list, in pin order.
    ///
    /// **Not a section of `home`, deliberately.** As a section it competed with
    /// the results for rows — whichever claimed a task first owned it, so
    /// pinning a task that later blocked moved its row out of Needs-you and
    /// under a heading about navigation while the menubar was orange. A strip
    /// cannot compete with anything. It is also visible while you type, where a
    /// section is not: `⌘1`–`⌘9` fire from anywhere, so hiding the list the
    /// moment you start typing hides the keys exactly when you would reach for
    /// them.
    public var pinned: [PaletteItem]

    public init(items: [PaletteItem] = [], home: [PaletteSection] = [],
                pinned: [PaletteItem] = []) {
        self.items = items
        self.home = home
        self.pinned = pinned
    }

    // MARK: Build

    /// Assemble an index from whatever the Store has loaded.
    ///
    /// Every argument defaults to empty on purpose: the index is built
    /// progressively as the concurrent reads land, so a half-filled index has
    /// to be a legal one. Searching before playbooks arrive should find tasks,
    /// not nothing.
    ///
    /// - Parameter blocked: slugs whose harness session is stopped waiting for
    ///   a human (`SessionAttention.isBlocked`). These lead the home list —
    ///   opening the bar should show what needs you before you type.
    public static func build(
        tasks: [FlowTask] = [],
        projects: [Project] = [],
        playbooks: [Playbook] = [],
        owners: [Owner] = [],
        tags: [TagCount] = [],
        reminders: [Reminder] = [],
        blocked: Set<String> = [],
        jumpList: JumpList = JumpList(),
        /// A version whose notes have not been read yet — surfaced once, at the
        /// top of home. Nil the rest of the time.
        unreadRelease: String? = nil,
        commands: [PaletteItem] = PaletteCommands.all
    ) -> PaletteIndex {
        var items: [PaletteItem] = []

        for t in tasks {
            items.append(item(for: t, blocked: blocked.contains(t.slug), jump: jumpList))
        }
        for p in projects {
            items.append(PaletteItem(
                id: "project:\(p.slug)", kind: .project, title: p.slug,
                subtitle: SessionRowLabel.secondary(slug: p.slug, name: p.name),
                keywords: ["project", p.status, p.priority],
                action: .openProject(p.slug),
                rank: p.status == "active" ? 0 : 1))
        }
        for p in playbooks {
            items.append(PaletteItem(
                id: "playbook:\(p.slug)", kind: .playbook, title: p.slug,
                keywords: ["playbook", "run", p.project].compactMap { $0 },
                action: .openPlaybook(p.slug)))
        }
        for o in owners {
            items.append(PaletteItem(
                id: "owner:\(o.slug)", kind: .owner, title: o.slug,
                subtitle: o.nextTickRelative.map { "next tick \($0)" },
                keywords: ["owner", o.status],
                action: .openOwner(o.slug),
                rank: o.status == "active" ? 0 : 1))
        }
        for t in tags {
            items.append(PaletteItem(
                id: "tag:\(t.tag)", kind: .tag, title: "#\(t.tag)",
                subtitle: "\(t.count) task\(t.count == 1 ? "" : "s")",
                keywords: ["tag", t.tag],
                action: .openTag(t.tag),
                rank: -t.count))   // biggest tag first on a tie
        }
        for r in reminders where !r.isCompleted {
            items.append(PaletteItem(
                id: "reminder:\(r.id.uuidString)", kind: .reminder, title: r.title,
                subtitle: r.tasks.map(\.slug).joined(separator: ", ").nonEmpty,
                keywords: ["reminder"] + r.tasks.map(\.slug),
                action: .openReminder(r.id)))
        }
        items.append(contentsOf: commands)

        // In pin order, and outside `items`: the strip is a fixed set of keys,
        // not something a query filters.
        let byslug = Dictionary(tasks.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = jumpList.slugs.compactMap { byslug[$0] }
            .map { item(for: $0, blocked: blocked.contains($0.slug), jump: jumpList) }

        return PaletteIndex(items: items,
                            home: homeSections(tasks: tasks, blocked: blocked,
                                               jumpList: jumpList,
                                               unreadRelease: unreadRelease,
                                               commands: commands),
                            pinned: pinned)
    }

    /// One task's row. Rank encodes "how reachable is this right now", which is
    /// what decides equal-scoring ties: a live session beats an in-progress
    /// task beats backlog, and done/archived sink to the bottom — they can't be
    /// opened at all (`FlowTask.canOpen`).
    /// One task's row.
    ///
    /// **No name on the row.** It used to be the subtitle (via
    /// `SessionRowLabel`), and on a real list it crowded the project and tags
    /// off the end of the line — `#aws #fram…` tells you nothing. The slug is
    /// what you act on, the project and tags are what you scan by, and the name
    /// is what you read once you have decided: it lives in the brief, one `→`
    /// away.
    ///
    /// It stays **searchable** as a keyword, which also puts it on the right
    /// side of the matcher's own rule: a slug is a token you abbreviate and
    /// matches fuzzily, a name is prose and matches by substring.
    static func item(for t: FlowTask, blocked: Bool, jump: JumpList? = nil) -> PaletteItem {
        var keywords = ["task", t.status, t.priority, t.name]
        keywords.append(contentsOf: t.tagList)
        if let p = t.projectName { keywords.append(p) }
        if let a = t.assignee { keywords.append(a) }
        if t.isLive { keywords.append("live") }
        if t.isWaiting { keywords.append("waiting") }
        if t.isStale { keywords.append("stale") }
        if t.isOverdue { keywords.append("overdue") }
        if blocked { keywords.append(contentsOf: ["blocked", "needs you", "attention"]) }

        let rank: Int
        if blocked { rank = -1 }
        else if t.isLive { rank = 0 }
        else if t.status == "in-progress" { rank = 1 }
        else if t.status == "backlog" { rank = 2 }
        else if t.isArchived { rank = 4 }
        else { rank = 3 }

        var badges: [PaletteBadge] = []
        if blocked { badges.append(.blocked) } else if t.isLive { badges.append(.live) }
        if t.isDueSoon, let label = t.dueLabel { badges.append(.due(label, overdue: t.isOverdue)) }
        if t.isWaiting { badges.append(.waiting(t.waitingOn)) }
        if t.isStale { badges.append(.stale(t.staleDays)) }
        if t.status == "done" { badges.append(.done) }
        if t.isArchived { badges.append(.archived) }

        return PaletteItem(
            id: "task:\(t.slug)", kind: .task, title: t.slug,
            keywords: keywords, action: .openTask(t.slug), rank: rank,
            badges: badges, jumpNumber: jump?.number(of: t.slug),
            project: t.projectName, tags: t.tagList)
    }

    /// The empty-query list: what needs you, then what's running, then the
    /// commands. Deliberately *not* everything — home answers "what am I in the
    /// middle of", and search answers "where is that thing". Backlog, done and
    /// archived tasks are findable by typing and nowhere else.
    static func homeSections(tasks: [FlowTask], blocked: Set<String>,
                             jumpList: JumpList = JumpList(),
                             unreadRelease: String? = nil,
                             commands: [PaletteItem]) -> [PaletteSection] {
        var seen = Set<String>()
        func take(_ ts: [FlowTask]) -> [PaletteItem] {
            ts.filter { seen.insert($0.slug).inserted }
              .map { item(for: $0, blocked: blocked.contains($0.slug), jump: jumpList) }
        }

        // **These `take` calls are order-sensitive**: each consumes the slugs it
        // uses, so whichever runs first owns a task that qualifies for two
        // sections. What needs answering is claimed first, and leads.
        //
        // The jump list is NOT among them any more — it is a strip now
        // (`PaletteIndex.pinned`), which is what stops it competing for rows at
        // all. A pinned task appears here under whichever section describes its
        // state, wearing its number.
        // **Archived work is excluded everywhere here.** Home is built from the
        // all-status list the palette loads (that is what makes search cover
        // done and archived), and an archived task can still carry
        // `status: in-progress` — so without this filter it was listed under
        // "In progress", wearing an archive box, in the one view that is
        // supposed to answer "what am I in the middle of". It stays findable by
        // typing, which is where it belongs.
        let active = tasks.filter { !$0.isArchived }
        let needsYou = take(active.filter { blocked.contains($0.slug) }.sortedBySlug())
        let live = take(active.filter { $0.isLive }.sortedBySlug())
        let rest = take(active.filter { $0.status == "in-progress" }.sortedByPriority())

        var sections: [PaletteSection] = []
        // Needs-you leads whatever else is on screen: it is the only section the
        // menubar icon is pointing at, and anything above it is something you
        // did not open the palette for.
        if !needsYou.isEmpty { sections.append(PaletteSection(title: "Needs you", items: needsYou)) }
        // Then, once per version: nobody goes looking for "what's new", so the
        // one moment it is worth saying is the first time you open the palette
        // on a version you have not read about. One row, and opening it retires
        // it.
        if let version = unreadRelease {
            sections.append(PaletteSection(title: "New in this version", items: [
                PaletteItem(id: "cmd:whats-new-banner", kind: .command,
                            title: "What's new in v\(version)",
                            subtitle: "Release notes",
                            keywords: ["changelog", "release notes", "version"],
                            action: .releaseNotes),
            ]))
        }
        if !live.isEmpty { sections.append(PaletteSection(title: "Live sessions", items: live)) }
        if !rest.isEmpty { sections.append(PaletteSection(title: "In progress", items: rest)) }
        sections.append(PaletteSection(title: "Commands", items: commands))
        return sections
    }

    // MARK: Search

    /// Everything in the index as one flat group, in a useful order.
    ///
    /// What a pushed list shows before you type. The home list is the root's
    /// answer to an empty query; inside a route an empty query means "show me
    /// all of it", which is a different question.
    public func listing(title: String) -> PaletteResults {
        let sorted = items.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.title < b.title
        }
        return PaletteResults(sections: [PaletteSection(title: title, items: sorted)])
    }

    /// An index over an explicit set of rows — a pushed route's contents.
    /// Carries no commands and no home list: inside a route, "Settings…" is
    /// not one of the answers.
    public static func of(_ items: [PaletteItem]) -> PaletteIndex {
        PaletteIndex(items: items, home: [])
    }

    /// Rows for a playbook's runs. A run is a task — `flow do <run-slug>`
    /// switches to it exactly like any other — so its row opens a tab too.
    public static func runItems(_ runs: [PlaybookRun]) -> [PaletteItem] {
        runs.map { run in
            PaletteItem(
                id: "run:\(run.slug)", kind: .task, title: run.slug,
                keywords: ["run", run.status, run.playbook].compactMap { $0 },
                action: .openTask(run.slug),
                rank: run.status == "in-progress" ? 0 : 1,
                // A run belongs to its playbook the way a task belongs to a
                // project, so it reads with the same folder glyph.
                project: run.playbook)
        }
    }

    /// Rank the whole index against one query.
    ///
    /// Results are sorted **globally** and only then grouped, so the first row
    /// is the best match in the app — not the best match in whichever group
    /// happens to sort first. Group headers follow the order their best member
    /// landed in.
    public func search(_ raw: String, limit: Int = 60) -> PaletteResults {
        let parsed = PaletteQuery.parse(raw)
        // A sigil the index can't honour is just a character: inside a route
        // there are no commands, and `@` should search rather than blank the
        // list with a scope nothing can satisfy.
        let pool = parsed.scope.map { s in items.filter { $0.kind == s } } ?? []
        let scoped = parsed.scope != nil && !pool.isEmpty
        let searchable = scoped ? pool : items
        // An unhonourable sigil is dropped rather than matched: inside a route
        // there are no commands, and `@tessera` should find the task, not fail
        // because no row contains an "@".
        let q = (parsed.scope != nil ? parsed.text : raw)
            .trimmingCharacters(in: .whitespaces)

        guard !q.isEmpty else {
            // A bare sigil lists what it scopes to; a bare query is the home
            // list, which answers a different question.
            guard scoped, let scope = parsed.scope else {
                return PaletteResults(sections: home)
            }
            return PaletteIndex.of(pool).listing(title: scope.sectionTitle)
        }

        var scored: [(item: PaletteItem, hit: PaletteMatcher.Hit)] = []
        for item in searchable {
            if let hit = PaletteMatcher.match(query: q, item: item) { scored.append((item, hit)) }
        }
        scored.sort { a, b in
            if a.hit.score != b.hit.score { return a.hit.score > b.hit.score }
            if a.item.kind.rank != b.item.kind.rank { return a.item.kind.rank < b.item.kind.rank }
            if a.item.rank != b.item.rank { return a.item.rank < b.item.rank }
            return a.item.title < b.item.title
        }
        let top = Array(scored.prefix(limit))

        var order: [PaletteKind] = []
        var grouped: [PaletteKind: [PaletteItem]] = [:]
        var highlights: [String: [Int]] = [:]
        for (item, hit) in top {
            if grouped[item.kind] == nil { order.append(item.kind) }
            grouped[item.kind, default: []].append(item)
            if !hit.titleOffsets.isEmpty { highlights[item.id] = hit.titleOffsets }
        }
        let sections = order.map {
            PaletteSection(title: $0.sectionTitle, items: grouped[$0] ?? [])
        }
        return PaletteResults(sections: sections, highlights: highlights)
    }
}

// MARK: - Geometry

/// Where the centered palette sits, and how it grows.
///
/// Pure rectangle arithmetic, kept out of the window controller so the harness
/// can hold it to the two rules that matter. Both are the sort of thing that
/// looks right on the machine it was written on and is wrong on a second
/// monitor, where nobody notices for weeks.
public enum PaletteGeometry {
    /// How far below the top of the usable screen the panel's top edge sits.
    /// Spotlight and every launcher since put themselves above the true centre:
    /// the eye lands high, and the list needs the room below it.
    public static let topFraction: CGFloat = 0.18

    /// The panel's frame on a given screen. `visible` is the screen's *visible*
    /// frame — menubar and Dock already subtracted.
    public static func frame(in visible: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let w = min(width, visible.width)
        let top = topEdge(in: visible)
        return CGRect(x: (visible.midX - w / 2).rounded(),
                      y: top - height, width: w, height: height)
    }

    /// The y of the panel's top edge on a screen.
    public static func topEdge(in visible: CGRect) -> CGFloat {
        visible.maxY - visible.height * topFraction
    }

    /// Resize to `height` **keeping the top edge fixed**, so the list grows
    /// downward. If the window stayed centred, every keystroke that changed the
    /// result count would slide the field out from under the cursor you are
    /// typing into.
    public static func resized(_ frame: CGRect, toHeight height: CGFloat,
                               topEdge: CGFloat) -> CGRect {
        CGRect(x: frame.origin.x, y: topEdge - height,
               width: frame.width, height: height)
    }

    /// Clamp a requested height to something a panel can be.
    public static func clampHeight(_ requested: CGFloat,
                                   min lower: CGFloat = 120,
                                   max upper: CGFloat = 640) -> CGFloat {
        Swift.min(Swift.max(requested.rounded(), lower), upper)
    }
}

// MARK: - Small helpers

private extension Array where Element == FlowTask {
    func sortedBySlug() -> [FlowTask] { sorted { $0.slug < $1.slug } }
}

private extension String {
    /// nil rather than "" — a subtitle of empty string would still lay out a line.
    var nonEmpty: String? { isEmpty ? nil : self }
}
