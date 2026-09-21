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
    /// Why a pin was just refused, shown briefly in the hint bar.
    @State private var jumpRefused: String?
    /// Measured: the hint bar wraps to a second row when the keys don't fit.
    @State private var hintsHeight: CGFloat = 34
    /// The ⌘K panel: whether it is up, and where its own cursor is.
    @State private var actionsOpen = false
    @State private var actionCursor = 0
    /// The app menu behind the brand mark. Clicked, never keyed — every entry
    /// in it is also an `@` command, which is the keyboard route.
    @State private var appMenuOpen = false
    /// Opening N tasks spawns N sessions — past a handful, ask first.
    @State private var confirmingBulkOpen = false
    private static let bulkOpenConfirmThreshold = 5

    // Fixed parts of the layout; the body gets whatever is left.
    // Measured against Raycast on the same display: its collapsed bar is 127px
    // at 2x, so 63.5pt of field row.
    private let fieldHeight: CGFloat = 64
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
            .mask(bottomFade(bodyHeight, active: route?.isDetail != true
                                         && contentHeight > bodyHeight + 1))

            if !store.selectedTaskSlugs.isEmpty { selectionBar }
            hints()
        }
        .background(PaletteSurface())
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if appMenuOpen {
                PaletteActionPanel(entries: PaletteActions.appMenu(),
                                   title: "flow-bar \(AppInfo.version)") { entry in
                    appMenuOpen = false
                    perform(entry.action)
                }
                .padding(.leading, 12)
                .padding(.bottom, max(hintsHeight, hintHeight) + 6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if actionsOpen, !actions.isEmpty {
                PaletteActionPanel(entries: actions, cursor: actionCursor) { runAction($0) }
                    .padding(.trailing, 12)
                    .padding(.bottom, max(hintsHeight, hintHeight) + 6)
            }
        }
        // A fresh open is a fresh search — and a fresh stack. Coming back to
        // where you were three levels deep is not something anyone wants from a
        // thing they summon to find one item.
        .onChange(of: store.paletteNonce) {
            query = ""
            cursor = 0
            stack = []
            store.paletteReadingDocument = false
            focus.take()
        }
        .onChange(of: query) {
            cursor = 0; matchIndex = 0; actionsOpen = false; appMenuOpen = false
        }
        // The jump panel hides over a document; the ⌘1–⌘9 keys do not.
        .onChange(of: route?.isDetail ?? false) { _, reading in
            store.paletteReadingDocument = reading
        }
        .onChange(of: cursor) { actionsOpen = false; appMenuOpen = false }
        .onChange(of: totalHeight(bodyHeight)) { _, h in onHeight(h) }
        .onAppear { onHeight(totalHeight(bodyHeight)) }
    }

    // MARK: Contents

    /// What the current route shows, ranked by the query.
    ///
    /// The root answers with the whole index; a pushed route answers with only
    /// its own rows and **no commands** — inside a project, "Settings…" is not
    /// one of the answers. An empty query means "all of it" here, where at the
    /// root it means "what am I in the middle of".
    private var results: PaletteResults {
        // Memoised: every `selected`, the height, the cursor and the ⌘K list
        // all derive from this, and the answer cannot change within a render.
        store.memoisedResults(key: route.map { "route:\($0.chip)" } ?? "root", query: query) {
            guard let route else { return store.palette.search(query) }
            if route.isDetail { return PaletteResults(sections: []) }
            let index = PaletteIndex.of(items(for: route))
            return query.isEmpty ? index.listing(title: route.chip) : index.search(query)
        }
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
            // **Where you are is said once, at the bottom.** A route chip used
            // to sit here too, so the same slug appeared three times on one
            // screen — chip, placeholder, and the footer pill — and the one in
            // the field was the worst of the three: it pushed the caret right on
            // every push, so the text you were typing started somewhere new
            // depending on how deep you had gone. The scope chip stays, because
            // it is not a place; it is a mode the query is in, and a scoped list
            // looks like a list that has mysteriously lost most of its rows
            // unless something says so out loud.
            if let scope = PaletteQuery.parse(query).chip {
                GlassGroup(spacing: 8) { chip(scope) }
            }
            PaletteField(
                text: $query,
                placeholder: route?.placeholder ?? PaletteQuery.rootPlaceholder,
                focus: focus,
                onMove: { move($0) },
                onJump: { jump($0) },
                onSubmit: { submit() },
                onExpand: { expand() },
                onCollapse: { collapse() },
                onCancel: { cancel() },
                onJumpTo: { jumpTo($0) },
                onToggleJump: { toggleJump() },
                onToggleSelection: { toggleSelection() },
                onActions: { toggleActions() },
                onCopy: { copySelectedSlug() })
            // Transient messages live up here, beside the field — in the hint
            // bar they shoved the keys around and truncated them, which is the
            // opposite of what a hint bar is for.
            if let jumpRefused {
                Text(jumpRefused)
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .lineLimit(1).fixedSize()
            }
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .frame(height: fieldHeight)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .glassPill(fallback: Theme.accent.opacity(0.28), tinted: true)
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
            VStack(alignment: .leading, spacing: 0) {
                if case .task(let slug) = route {
                    briefPills(slug).padding(.horizontal, 18)
                }
                // **No horizontal padding here.** The scroll view must span the
                // full panel width or its overlay scroller draws 18pt in from
                // the edge — inside the text column, on top of the last word of
                // every long line. The text's own inset lives on its container
                // instead (`MarkdownDocument`).
                MarkdownDocument(source: markdown, find: query, current: matchIndex,
                                 accentHeadings: true) {
                    if matchCount != $0 { matchCount = $0 }
                }
            }
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
        // Slug, project and tags are NOT in the document — they are pills
        // above it (`briefPills`). In the prose they were another line to read;
        // as pills they are a shape you recognise without reading, and they stay
        // put while the document scrolls.
        var parts = ["# \(d.name)"]
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

    /// The footer: what ↵ does, and the way to everything else.
    ///
    /// **One shape, every route.** The bar is two zones and they never swap:
    /// flat text on the left for whatever this view happens to offer, and one
    /// floating capsule on the right holding the primary action and `⌘K`. It
    /// was built per-branch, so the capsule existed at the root and nowhere
    /// else — the same two keys were a control in one view and a run of grey
    /// labels in the next, which is exactly the tell that a shape is decorative
    /// rather than meaningful. Here the capsule *is* the claim "these two are
    /// always here", so it has to be always there.
    ///
    /// **Two items in it, never more.** Naming every key on the right is what
    /// made this bar outgrow the window — hints were first cut to fit, so which
    /// keys existed depended on the width, then wrapped to a second row. Behind
    /// ⌘K a row can gain a tenth action and the footer does not notice.
    private func hints() -> some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 14) {
                AppMenuButton(isOpen: appMenuOpen, label: route?.chip) {
                    appMenuOpen.toggle()
                    actionsOpen = false
                }
                hintsLeading
                Spacer(minLength: 8)
                hintsTrailing
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintsHeight = $0 }
    }

    /// What is left on the left: the find's state, and nothing else.
    ///
    /// **Every key that used to sit here is taught by something better.** `esc`
    /// and `←` are the two keys nobody has to be told go back. `⌥↵` skip-prompts
    /// and `⌘J` pin are row actions, so they belong in `⌘K` with the other
    /// eight — naming two of ten in the footer only made the bar's contents look
    /// arbitrary. The accepted cost is that `@` and the ⌘-hold are no longer
    /// advertised anywhere but the changelog; they were the two genuinely
    /// unteachable gestures, and this trades their discovery for a bar that
    /// says one thing.
    @ViewBuilder
    private var hintsLeading: some View {
        if route?.isDetail == true { findState }
    }

    /// The list runs out under the footer rather than stopping at a rule.
    ///
    /// **A rule says "the list ends here", which is a lie whenever it scrolls.**
    /// A fade says "there is more", and it says it in the same place the
    /// scrollbar would if there were room for one. It is applied only when the
    /// content actually overflows: fading the last row of a list that fits would
    /// be dimming something for no reason, which is the tell that the effect is
    /// decoration rather than information.
    @ViewBuilder
    private func bottomFade(_ height: CGFloat, active: Bool) -> some View {
        if active, height > 0 {
            let fade = min(34, height * 0.3)
            LinearGradient(stops: [
                .init(color: .black, location: (height - fade) / height),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        } else {
            Color.black
        }
    }

    /// Found nothing, or something to step through. **Nothing at all while the
    /// query is empty**: "type to find" sat here, under a field whose own
    /// placeholder already reads "Search <slug>'s brief and notes…", so the
    /// footer's one line was spent repeating the instruction two inches above
    /// it. What is left is the two states the placeholder cannot report.
    @ViewBuilder
    private var findState: some View {
        if query.isEmpty {
            EmptyView()
        } else if matchCount == 0 {
            Text("no matches").font(.system(size: 12)).foregroundStyle(.tertiary)
        } else {
            findBar
        }
    }

    /// The two things that are always here, in their own floating capsule — the
    /// shape says "these are the controls", where one more run of grey text
    /// says "these are more labels".
    @ViewBuilder
    private var hintsTrailing: some View {
        let primary = primaryHint
        if primary != nil || !actions.isEmpty {
            HStack(spacing: 14) {
                if let primary {
                    hint("↵", primary.label, action: primary.run)
                    if !actions.isEmpty { Divider().frame(height: 14).opacity(0.35) }
                }
                // **Clickable, like everything else in this bar.** It was the
                // one control drawn as a control and wired as a caption: it
                // looks exactly like the primary beside it, which is a promise,
                // and clicking it did nothing.
                if !actions.isEmpty { hint("⌘K", "Actions") { _ = toggleActions() } }
            }
            .frame(height: Theme.footerControl)
            .padding(.horizontal, 12)
            .glassSurface(cornerRadius: Theme.footerControl / 2, fallback: Theme.chip)
        }
    }

    /// What ↵ does here, and — where ↵ is also a thing you might click — how to
    /// do it. Nil in a document, which has nothing to open.
    private var primaryHint: (label: String, run: (() -> Void)?)? {
        if actionsOpen {
            return ("Run", { if let e = actions[safe: actionCursor] { runAction(e) } })
        }
        if case .task(let slug) = route {
            guard store.paletteDetail?.canOpen != false else { return nil }
            return ("Open", { onAction(.openTask(slug)) })
        }
        if route == .releaseNotes { return nil }
        return (primaryLabel, { submit() })
    }

    private func totalHeight(_ body: CGFloat) -> CGFloat {
        fieldHeight + body + max(hintsHeight, hintHeight) + 2
            + (store.selectedTaskSlugs.isEmpty ? 0 : 31)
    }

    /// The jump list: one row of numbered chips, always on screen.
    ///
    /// **A strip rather than a section**, for two reasons that only showed up in
    /// use. As a section it competed with the results for rows, so pinning a
    /// task that later blocked moved its row out of Needs-you while the menubar
    /// was orange. And a section only renders on an empty query, which hid the
    /// list the moment you started typing — while `⌘1`–`⌘9` kept working from
    /// anywhere. A key you cannot see when you would reach for it is a key you
    /// do not use.
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

    /// What ↵ does to the row in front of you, in one word.
    private var primaryLabel: String {
        if !store.selectedTaskSlugs.isEmpty { return "Open \(store.selectedTaskSlugs.count)" }
        return selectedEnters ? "Enter" : "Open"
    }

    /// The task's identifying facts, as pills above the document.
    ///
    /// **Shape rather than colour.** A slug, a project and a tag are three
    /// different kinds of thing, and the difference has to survive a glance.
    /// Colour-coding them was tried and read as decoration; a pill is a shape
    /// you recognise without reading it, and it costs no palette to learn.
    /// They sit outside the scroll view, so they stay put while the brief moves.
    @ViewBuilder
    private func briefPills(_ slug: String) -> some View {
        // No slug pill: the footer's mark carries it, and the placeholder says
        // it again. Saying it a third time is not emphasis, it is noise.
        let item = paletteItem(for: slug)
        GlassGroup(spacing: 8) {
            WrapLayout(spacing: 6, lineSpacing: 4) {
                if let project = item?.project { pill(project, icon: "folder") }
                ForEach(item?.tags ?? [], id: \.self) { tag in
                    pill("#\(tag)", icon: nil)
                }
            }
        }
        // Equal above and below: the row sat 10pt from the field and 2pt from
        // the document, so it read as part of the text rather than a header.
        .padding(.vertical, 10)
        .opacity(item?.project == nil && (item?.tags.isEmpty ?? true) ? 0 : 1)
    }

    private func pill(_ text: String, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9))
            }
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassPill(fallback: Theme.chip)
    }

    /// The palette's row for a slug, for facts the `TaskDetail` doesn't carry.
    private func paletteItem(for slug: String) -> PaletteItem? {
        store.palette.items.first { $0.id == "task:\(slug)" }
    }

    /// The actions for whatever is in front of you — the selected row, or the
    /// brief you are reading. A brief is a place you have *already* chosen a
    /// task, so it is if anything the more likely place to want them.
    private var actions: [PaletteActions.Entry] {
        let item: PaletteItem?
        if case .task(let slug) = route { item = paletteItem(for: slug) }
        else if route?.isDetail == true { item = nil }
        else { item = selected }
        guard let item else { return [] }
        let slug = selectedTaskSlug ?? routeTaskSlug
        return PaletteActions.list(for: item, context: .init(
            isPinned: slug.map { store.jumpList.contains($0) } ?? false,
            isInBatch: slug.map { store.selectedTaskSlugs.contains($0) } ?? false,
            batchCount: store.selectedTaskSlugs.count,
            batch: store.orderedSelection,
            isViewingBrief: route?.isDetail == true))
    }

    private func runAction(_ entry: PaletteActions.Entry) {
        actionsOpen = false
        // "View brief" is navigation inside the palette, not something to hand
        // to the window layer.
        if entry.id == "brief" { expand(); return }
        switch entry.action {
        case .togglePin(let slug): _ = store.toggleJump(slug)
        case .toggleBatch(let slug): store.toggleSelection(slug)
        default: perform(entry.action)
        }
    }

    private func toggleActions() -> Bool {
        guard !actions.isEmpty else { return false }
        actionsOpen.toggle()
        actionCursor = 0
        return true
    }

    private func copySelectedSlug() -> Bool {
        guard let slug = selectedTaskSlug else { return false }
        store.copyToPasteboard(slug)
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

    /// A keyboard hint: what it does, then the keys that do it.
    ///
    /// **The action is named first, and a chord is one cap per key.** `⌘K` set
    /// in a single chip reads as one key with an odd name; two caps say what the
    /// hands do. Leading with the verb matches the order you think in — you want
    /// to open something, then you look for how — and it is why the footer can
    /// be read left to right without decoding symbols first.
    @ViewBuilder
    private func hint(_ key: String, _ label: String,
                      action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            HStack(spacing: 3) {
                ForEach(KeyCaps.split(key), id: \.self) { cap in
                    // `verbatim`, because `Text("…")` takes a
                    // LocalizedStringKey and the format parser eats a bare "@" —
                    // the Commands hint rendered as an empty cap while every
                    // other key showed fine. **Not `.rounded`** either: SF
                    // Rounded has no "@" glyph at all.
                    Text(verbatim: cap)
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 12)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chip))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                }
            }
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
    private func activate(_ item: PaletteItem) { perform(item.action) }

    /// **The one place that decides whether an action stays in the panel.**
    /// An action carrying a route is navigation and is pushed here; everything
    /// else is handed to the window layer. Both menus and ↵ go through it, which
    /// is why "What's new" from the app menu now opens the changelog *in* the
    /// palette — reached any other way it always had, and a menu that leaves the
    /// panel to show something the panel can show is a different feature wearing
    /// the same name.
    private func perform(_ action: PaletteAction) {
        if let route = action.route { push(route) } else { onAction(action) }
    }

    // MARK: Keyboard

    private func move(_ delta: Int) {
        // While the actions panel is up it owns the arrows — there is only ever
        // one list taking the keyboard.
        if actionsOpen {
            actionCursor = min(max(actionCursor + delta, 0), max(actions.count - 1, 0))
            return
        }
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
        if actionsOpen {
            if let entry = actions[safe: actionCursor] { runAction(entry) }
            return
        }
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
        // Pinning something finished would hand it a number that opens nothing,
        // and the next prune would take it away again — refuse rather than
        // accept and quietly undo. Unpinning always works.
        guard store.jumpList.contains(slug) || store.isOpenable(slug) else {
            jumpRefused = "that task is finished — nothing to jump to"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                jumpRefused = nil
            }
            return true
        }
        let change = store.toggleJump(slug)
        if case .full = change {
            jumpRefused = "jump list is full (9)"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                jumpRefused = nil
            }
        }
        return true
    }

    /// The slug of the brief being read, if that is where you are.
    private var routeTaskSlug: String? {
        if case .task(let slug) = route { return slug }
        return nil
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
        if appMenuOpen { appMenuOpen = false }
        else if actionsOpen { actionsOpen = false }
        else if confirmingBulkOpen { confirmingBulkOpen = false }
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
