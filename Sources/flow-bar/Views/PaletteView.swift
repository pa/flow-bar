import FlowBarCore
import SwiftUI

/// The centered palette — one field, one list, one hint bar, and a stack it
/// navigates **inside itself**.
///
/// **The panel is a mode, not a shortcut into the popover.** It used to hand
/// anything that wasn't "open a task" back to the menubar window, which meant
/// looking up a project closed the thing you were typing into and reopened the
/// app somewhere else. Now a container is *entered*: the stack pushes, a chip
/// appears in the field, the field starts filtering what you entered, and Esc
/// pops. Tab expands a row into its detail, so a task's brief and its notes
/// read here too.
///
/// Inside a brief the field becomes a **find**: the same fuzzy ladder as the
/// result list, with every match highlighted **in place** in the document
/// (`DocumentSearch` + `MarkdownText(find:)`). No second list — you are reading
/// a document, so the find lights up the words where they are.
///
/// Multi-open works here too, sharing the popover's `selectedTaskSlugs` so a
/// batch built in one window is the same batch in the other.
///
/// What still hands off is what genuinely needs a window the panel doesn't
/// have: task intake, the reminder form, Settings, and the Overview grid.
struct PaletteView: View {
    @ObservedObject var store: Store
    let focus: PaletteFocus
    /// Run something the palette can't do itself. The controller dismisses
    /// the panel and routes it.
    let onAction: (PaletteAction) -> Void
    let onClose: () -> Void
    /// The panel resizes to fit its contents, anchored at the top edge.
    let onHeight: (CGFloat) -> Void

    @State private var query = ""
    @State private var cursor = 0
    @State private var stack: [PaletteRoute] = []
    @State private var contentHeight: CGFloat = 0
    /// Find-in-brief state: which match is current, and how many there are.
    @State private var matchIndex = 0
    @State private var matchCount = 0
    /// Briefly true when a pin was refused because the list is full.
    @State private var jumpFull = false
    /// Opening N tasks spawns N sessions — past a handful, ask first.
    @State private var confirmingBulkOpen = false
    private static let bulkOpenConfirmThreshold = 5

    // Fixed parts of the layout; the body gets whatever is left.
    private let fieldHeight: CGFloat = 60
    private let hintHeight: CGFloat = 34
    private let maxListHeight: CGFloat = 400
    private let emptyHeight: CGFloat = 112

    private var route: PaletteRoute? { stack.last }

    var body: some View {
        let results = self.results
        let flat = results.flat
        let index = min(max(cursor, 0), max(rowCount - 1, 0))
        let bodyHeight = self.bodyHeight(results)

        return VStack(spacing: 0) {
            field
            Divider().opacity(0.5)
            Group {
                if route?.isDetail == true {
                    detail
                } else if results.isEmpty {
                    empty
                } else {
                    list(results, flat: flat, index: index)
                }
            }
            .frame(height: bodyHeight)
            if !store.selectedTaskSlugs.isEmpty {
                Divider().opacity(0.5)
                selectionBar
            }
            Divider().opacity(0.5)
            hints(count: flat.count)
        }
        .background(PaletteSurface())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        // A fresh open is a fresh search — and a fresh stack. Coming back to
        // where you were three levels deep is not something anyone wants from a
        // thing they summon to find one item.
        .onChange(of: store.paletteNonce) {
            query = ""
            cursor = 0
            stack = []
            focus.take()
        }
        .onChange(of: query) { cursor = 0; matchIndex = 0 }
        .onChange(of: fieldHeight + hintHeight + bodyHeight + 2) { _, h in onHeight(h) }
        .onAppear { onHeight(fieldHeight + hintHeight + bodyHeight + 2) }
    }

    // MARK: Contents

    /// What the current route shows, ranked by the query.
    ///
    /// The root answers with the whole index; a pushed route answers with only
    /// its own rows and **no commands** — inside a project, "Settings…" is not
    /// one of the answers. An empty query means "all of it" here, where at the
    /// root it means "what am I in the middle of".
    private var results: PaletteResults {
        guard let route else { return store.palette.search(query) }
        if route.isDetail { return PaletteResults(sections: []) }
        let index = PaletteIndex.of(items(for: route))
        return query.isEmpty ? index.listing(title: route.chip) : index.search(query)
    }

    private func items(for route: PaletteRoute) -> [PaletteItem] {
        func fromTasks(_ tasks: [FlowTask]) -> [PaletteItem] {
            PaletteIndex.build(tasks: tasks, blocked: blockedSlugs, commands: []).items
        }
        switch route {
        case .task, .releaseNotes:
            return []
        case .project:
            return fromTasks(store.projectTasks)
        case .tag:
            return fromTasks(store.tagTasks)
        case .owner:
            return fromTasks(store.ownerTasks)
        case .playbook(let slug):
            return PaletteIndex.runItems(store.runs.filter { $0.playbook == slug })
        case .list(let kind):
            switch kind {
            case .needsYou:   return fromTasks(needsYouTasks)
            case .inProgress: return fromTasks(store.tasks)
            // From the full list the palette already loads — no extra read, and
            // archived backlog rows stay out of it.
            case .backlog:
                return fromTasks(store.allTasks.filter {
                    $0.status == "backlog" && !$0.isArchived
                }.sortedByPriority())
            case .projects:
                return PaletteIndex.build(projects: store.metrics?.projects ?? [],
                                          commands: []).items
            case .playbooks:
                return PaletteIndex.build(playbooks: store.playbooks, commands: []).items
            case .owners:
                return PaletteIndex.build(owners: store.metrics?.owners ?? [],
                                          commands: []).items
            case .tags:
                return PaletteIndex.build(tags: store.metrics?.tags ?? [], commands: []).items
            case .reminders:
                return PaletteIndex.build(reminders: store.reminders, commands: []).items
            }
        }
    }

    /// Everything that is actually waiting on a person: stopped sessions, the
    /// owners' questions, then overdue and waiting work.
    private var needsYouTasks: [FlowTask] {
        guard let m = store.metrics else { return [] }
        let blocked = blockedSlugs
        var seen = Set<String>()
        return (m.inProgress.filter { blocked.contains($0.slug) }
                + m.questions
                + m.inProgress.filter { $0.isOverdue || $0.isWaiting })
            .filter { seen.insert($0.slug).inserted }
    }

    /// Sampled, not observed — see `Store.rebuildPalette` for why the session
    /// monitor must not drive this view's layout.
    private var blockedSlugs: Set<String> {
        store.sessionAlertsEnabled ? Set(store.sessionMonitor.blockedRows.map(\.slug)) : []
    }

    /// How many rows the cursor can move through right now. A brief has none —
    /// it is a document, not a list — so ↑↓ have nothing to run off the end of.
    private var rowCount: Int {
        route?.isDetail == true ? 0 : results.count
    }

    private func bodyHeight(_ results: PaletteResults) -> CGFloat {
        if route?.isDetail == true { return maxListHeight }
        if results.isEmpty { return emptyHeight }
        return min(max(contentHeight, 44), maxListHeight)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            // One chip per level. Two is already deep for a thing you summoned
            // to find one item, so a breadcrumb beats a single "back" label.
            ForEach(Array(stack.enumerated()), id: \.offset) { _, r in
                chip(r.chip)
            }
            // A scoped query looks like a list that has mysteriously lost most
            // of its rows unless the scope says so out loud.
            if let scope = PaletteQuery.parse(query).chip { chip(scope) }
            PaletteField(
                text: $query,
                placeholder: route?.placeholder ?? "Search tasks, projects, commands…",
                focus: focus,
                onMove: { move($0) },
                onJump: { jump($0) },
                onSubmit: { submit() },
                onExpand: { expand() },
                onCollapse: { collapse() },
                onCancel: { cancel() },
                onJumpTo: { jumpTo($0) },
                onToggleJump: { toggleJump() },
                onToggleSelection: { toggleSelection() })
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .frame(height: fieldHeight)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.28)))
    }

    private var isLoading: Bool {
        switch route {
        case .none: return store.paletteLoading
        case .task: return store.paletteDetailLoading
        case .releaseNotes: return false
        case .project: return store.projectTasksLoading
        case .tag: return store.tagTasksLoading
        case .owner: return store.ownerTasksLoading
        case .playbook: return store.playbooksLoading
        case .list(.backlog): return store.paletteLoading
        case .list: return store.metricsLoading
        }
    }

    // MARK: List

    private func list(_ results: PaletteResults, flat: [PaletteItem], index: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(results.sections) { section in
                        PaletteSectionHeader(title: section.title,
                                             count: section.items.count, spacious: true)
                        ForEach(section.items) { item in
                            Button { activate(item) } label: {
                                PaletteRow(item: item,
                                           highlight: results.highlight(for: item),
                                           selected: item.id == flat[safe: index]?.id,
                                           checked: isChecked(item),
                                           spacious: true)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .help(paletteHelp(item))
                        }
                    }
                }
                .padding(.vertical, 6)
                // Drives the panel's height, so the window fits its results
                // instead of leaving a fixed void under three rows.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
            }
            // Keeping the cursor visible is the one thing the list owes the
            // keyboard. Deliberately un-animated: a scroll that eases while you
            // hold ↓ lands you somewhere you weren't looking.
            .onChange(of: index) { _, i in
                guard let id = flat[safe: i]?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(emptyTitle).font(.system(size: 15)).foregroundStyle(.secondary)
            if !query.isEmpty, route == nil {
                Text("Searched tasks, projects, playbooks, owners, tags and commands")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !query.isEmpty {
            return route?.isDetail == true ? "Nothing in this brief or its notes" : "No matches"
        }
        if isLoading { return "Loading…" }
        switch route {
        case .none: return "Nothing in flight"
        case .list(.needsYou): return "Nothing needs you"
        default: return "Nothing here"
        }
    }

    // MARK: Detail

    /// A task's brief and its notes, read inside the panel.
    ///
    /// The field keeps working here: it filters the notes, and drops the brief
    /// when the brief doesn't match. That is what makes it honest to leave a
    /// focused text field on screen in a view that isn't a list.
    @ViewBuilder
    private var detail: some View {
        if let markdown = documentSource {
            MarkdownDocument(source: markdown, find: query, current: matchIndex) {
                if matchCount != $0 { matchCount = $0 }
            }
            .padding(.horizontal, 18)
        } else if store.paletteDetailLoading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if route == .releaseNotes {
            // A `swift run` build has no bundle to read them from.
            Text("No release notes are bundled with this build.")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Couldn’t load this brief.")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whatever document the current route is showing.
    ///
    /// The reader does not care which: a brief and a set of release notes are
    /// both markdown, and they get the same scrolling, the same find and the
    /// same highlighting for free.
    private var documentSource: String? {
        switch route {
        // The whole changelog, newest first: the history is the part you go
        // looking for, and the find bar can search all of it.
        case .releaseNotes: return AppInfo.changelog
        case .task: return store.paletteDetail.map { documentMarkdown($0) }
        default: return nil
        }
    }

    /// The brief and its notes as one markdown document.
    ///
    /// One document rather than a stack of rendered blocks, because a find has
    /// to be able to scroll to a match and a `ScrollViewReader` can only reach
    /// a view, never a line inside one. The per-note tinted cards are the cost;
    /// a rule and a heading say the same thing in a document you are reading.
    private func documentMarkdown(_ d: TaskDetail) -> String {
        var parts = ["# \(d.name)", "`\(d.slug)`"]
        let brief = TaskDetailView.dropLeadingTitle(d.brief)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(brief.isEmpty ? "*No brief written for this task yet.*" : brief)
        if !d.updates.isEmpty {
            parts.append("---")
            parts.append("## Recent updates")
            for u in d.updates {
                parts.append("### \(u.date) — \(u.title)")
                parts.append(TaskDetailView.dropLeadingTitle(u.content))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Step to the next/previous match, wrapping — the one thing every editor's
    /// find bar does, and the reason a match count is worth showing at all.
    private func stepMatch(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = ((matchIndex + delta) % matchCount + matchCount) % matchCount
    }

    // MARK: Hints

    private func hints(count: Int) -> some View {
        HStack(spacing: 14) {
            if route == .releaseNotes {
                hint("←", query.isEmpty ? "Back" : "Clear") { collapse() }
                if query.isEmpty {
                    Text("type to find").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else if matchCount == 0 {
                    Text("no matches").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    findBar
                }
            } else if case .task(let slug) = route {
                // Clickable, because a modifier is invisible and this is the
                // one place you have decided to open a specific task.
                if store.paletteDetail?.canOpen != false {
                    hint("↵", "Open") { onAction(.openTask(slug)) }
                    // Only where it can do anything: on a live task `flow do`
                    // focuses the running tab and returns before it builds a
                    // command line, so the flag never reaches the harness.
                    if !store.hasLiveSession(slug) {
                        hint("⌥↵", "Skip prompts") { onAction(.openTaskSkippingPrompts(slug)) }
                    }
                }
                if let slug = selectedTaskSlug {
                    hint("⌘J", store.jumpList.contains(slug) ? "Unpin" : "Pin") {
                        _ = toggleJump()
                    }
                }
                hint("←", query.isEmpty ? "Back" : "Clear") { collapse() }
                if query.isEmpty {
                    Text("type to find").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else if matchCount == 0 {
                    Text("no matches").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    findBar
                }
            } else {
                hint("↵", selectedEnters ? "Enter" : "Open")
                if selectedCanSkipPrompts { hint("⌥↵", "Skip prompts") }
                if let slug = selectedTaskSlug {
                    hint("⌘J", store.jumpList.contains(slug) ? "Unpin" : "Pin")
                    hint("⌘↵", store.selectedTaskSlugs.contains(slug) ? "Deselect" : "Select")
                }
                if selectedExpands { hint("→", "Brief") }
                else if selectedEnters { hint("→", "Open") }
                if !stack.isEmpty || !query.isEmpty {
                    hint("←", query.isEmpty ? "Back" : "Clear")
                }
                hint("esc", escLabel)
                // Only on an empty root: a sigil you have to be told about is
                // worth one line of screen while there is nothing else to say.
                if stack.isEmpty, query.isEmpty { hint("@", "Commands") }
            }
            Spacer()
            if jumpFull {
                Text("jump list is full (9)")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if count > 0, route?.isDetail != true {
                Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: hintHeight)
    }

    /// What is in the batch, and the two things you can do with it.
    private var selectionBar: some View {
        let n = store.selectedTaskSlugs.count
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
            Text("\(n) selected").font(.system(size: 12, weight: .medium))
            Spacer()
            if confirmingBulkOpen {
                Text("Open \(n) sessions?")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Button("Cancel") { confirmingBulkOpen = false }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open all") { openSelected() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            } else {
                Button("Clear") { store.clearSelection() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open all (\(n))") { openSelected() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
    }

    /// Open the batch. Past a handful this spawns a lot of terminals, so the
    /// first press asks — the same threshold and the same wording as the
    /// popover, because it is the same action.
    private func openSelected() {
        let batch = store.orderedSelection
        guard !batch.isEmpty else { return }
        if batch.count > Self.bulkOpenConfirmThreshold && !confirmingBulkOpen {
            confirmingBulkOpen = true
            return
        }
        confirmingBulkOpen = false
        onAction(.openBatch(batch))
    }

    /// ⌘↵ — add the current row to the batch, or take it out again.
    private func toggleSelection() -> Bool {
        guard let slug = selectedTaskSlug else { return false }
        store.toggleSelection(slug)
        confirmingBulkOpen = false
        return true
    }

    /// Count and step, the way every editor's find does it.
    private var findBar: some View {
        HStack(spacing: 6) {
            Text("\(matchIndex + 1) of \(matchCount)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .monospacedDigit()
            Button { stepMatch(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Previous match (↑)")
            Button { stepMatch(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Next match (↓)")
        }
    }

    private var escLabel: String {
        if !query.isEmpty { return "Clear" }
        if !store.selectedTaskSlugs.isEmpty { return "Deselect" }
        return stack.isEmpty ? "Close" : "Back"
    }

    private var selected: PaletteItem? {
        let flat = results.flat
        return flat[safe: min(max(cursor, 0), max(flat.count - 1, 0))]
    }
    private var selectedEnters: Bool { selected?.entersOnPrimary ?? false }
    private func isChecked(_ item: PaletteItem) -> Bool {
        switch item.action {
        case .openTask(let slug), .openTaskSkippingPrompts(let slug):
            return store.selectedTaskSlugs.contains(slug)
        default: return false
        }
    }

    private var selectedIsTask: Bool {
        if case .openTask = selected?.action { return true }
        return false
    }

    /// A skip-prompts open only means something for a session that isn't
    /// already running — a first bootstrap, or a resume of a task whose tab was
    /// closed. Advertising a key that does nothing is worse than not having it.
    private var selectedCanSkipPrompts: Bool {
        selectedIsTask && !(selected?.hasLiveSession ?? false)
    }
    private var selectedExpands: Bool {
        guard let s = selected else { return false }
        return !s.entersOnPrimary && s.detailRoute != nil
    }

    /// A keyboard hint. Given an action it becomes a button, so the same thing
    /// is reachable by key or by mouse without a second control existing.
    @ViewBuilder
    private func hint(_ key: String, _ label: String,
                      action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(label == "Skip prompts"
                      ? "Open without permission prompts — applies to this open only"
                      : label)
        } else {
            content
        }
    }

    // MARK: Navigation

    private func push(_ route: PaletteRoute) {
        stack.append(route)
        query = ""
        cursor = 0
        contentHeight = 0
        load(route)
    }

    private func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        query = ""
        cursor = 0
        contentHeight = 0
        if let r = stack.last { load(r) }
    }

    /// Fetch what a route shows. Every one of these loaders already exists for
    /// the popover's drill-ins — the palette is a second caller, not a second
    /// implementation.
    private func load(_ route: PaletteRoute) {
        switch route {
        case .task(let slug):    store.loadPaletteDetail(slug)
        // Reading them is what retires the banner.
        case .releaseNotes:      store.markReleaseNotesSeen()
        case .project(let slug): store.loadProjectTasks(slug)
        case .tag(let tag):      store.loadTagTasks(tag)
        case .owner(let slug):   store.loadOwnerTasks(slug)
        case .playbook:          if store.runs.isEmpty { store.refreshPlaybooks() }
        case .list(let kind):
            switch kind {
            case .playbooks: if store.playbooks.isEmpty { store.refreshPlaybooks() }
            case .backlog:   if store.allTasks.isEmpty { store.refreshPalette() }
            case .reminders: break   // reminders are local, already in memory
            default:         if store.metrics == nil { store.refreshMetrics() }
            }
        }
    }

    /// ↵ — enter a container, or act on the world.
    private func activate(_ item: PaletteItem) {
        if let route = item.action.route { push(route) } else { onAction(item.action) }
    }

    // MARK: Keyboard

    private func move(_ delta: Int) {
        if route?.isDetail == true { stepMatch(delta); return }
        let n = rowCount
        guard n > 0 else { return }
        // No wrapping. A list that jumps from the last row back to the first is
        // a list you can lose your place in while holding a key down.
        cursor = min(max(cursor + delta, 0), n - 1)
    }

    private func jump(_ direction: Int) {
        if route?.isDetail == true {
            matchIndex = direction < 0 ? 0 : max(matchCount - 1, 0)
            return
        }
        let n = rowCount
        guard n > 0 else { return }
        cursor = direction < 0 ? 0 : n - 1
    }

    private func submit() {
        // A non-empty selection wins: ↵ commits the thing you have been
        // building, which the selection bar makes visible. Same rule as the
        // popover's search field.
        if !store.selectedTaskSlugs.isEmpty {
            openSelected()
            return
        }
        if route?.isDetail == true {
            // The only thing ↵ can mean while reading a brief.
            if case .task(let slug) = route, store.paletteDetail?.canOpen != false {
                onAction(.openTask(slug))
            }
            return
        }
        guard let item = selected else { return }
        activate(item)
    }

    /// → (or ⇥) — expand the selected row into its own route. On a task that
    /// is its brief, which ↵ can't be: ↵ has to stay "open the tab".
    private func expand() {
        guard route?.isDetail != true, let r = selected?.detailRoute else { return }
        push(r)
    }

    /// ⌘1…⌘9 — open a pinned task from anywhere in the palette, without
    /// looking at the list. That is the whole point: the number is a reflex,
    /// so it must work while you are three routes deep and mid-query.
    private func jumpTo(_ number: Int) -> Bool {
        guard let slug = store.jumpTarget(number) else { return false }
        onAction(.openTask(slug))
        return true
    }

    /// ⌘J — pin or unpin the selected task.
    private func toggleJump() -> Bool {
        guard let slug = selectedTaskSlug else { return false }
        let change = store.toggleJump(slug)
        if case .full = change {
            jumpFull = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                jumpFull = false
            }
        }
        return true
    }

    /// The slug of whatever a jump action would act on: the selected row, or
    /// the brief you are reading.
    private var selectedTaskSlug: String? {
        if case .task(let slug) = route { return slug }
        switch selected?.action {
        case .openTask(let slug), .openTaskSkippingPrompts(let slug): return slug
        default: return nil
        }
    }

    /// ← steps back one thing: what you typed, then where you are.
    ///
    /// It does not skip straight to popping while a query is up. Losing a
    /// route you navigated into because you wanted to clear four characters is
    /// the kind of thing that makes people stop trusting a key.
    private func collapse() {
        if !query.isEmpty { query = ""; cursor = 0 } else { pop() }
    }

    /// Esc unwinds the same way, and closes the panel once there is nothing
    /// left to unwind. A wrong query is far more common than a wrong summon.
    private func cancel() {
        if confirmingBulkOpen { confirmingBulkOpen = false }
        else if !query.isEmpty { query = ""; cursor = 0 }
        else if !store.selectedTaskSlugs.isEmpty { store.clearSelection() }
        else if !stack.isEmpty { pop() }
        else { onClose() }
    }
}

/// The panel's backdrop. Same material and contrast floor as the popover — see
/// `PopoverSurface` for why the dark scrim is not optional.
struct PaletteSurface: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            Theme.scrim
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
