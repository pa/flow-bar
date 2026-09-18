import FlowBarCore
import SwiftUI

/// App sections, shown as the left icon rail.
enum Section: String, CaseIterable, Identifiable {
    /// No `search` here on purpose: search is the ⌥Space panel's whole job, and a
    /// second search surface inside the mouse-driven window is a second front
    /// door to the same room. The popover browses; the panel searches.
    case dashboard, tasks, inbox, playbooks, projects, owners, tags, reminders
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .tasks: return "In progress"
        case .inbox: return "Needs you"
        case .playbooks: return "Playbooks"
        case .projects: return "Projects"
        case .owners: return "Owners"
        case .tags: return "Tags"
        case .reminders: return "Reminders"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "speedometer"
        case .tasks: return "list.bullet"
        case .inbox: return "tray.full"
        case .playbooks: return "play.rectangle"
        case .projects: return "folder"
        case .owners: return "gearshape.2"
        case .tags: return "number"
        case .reminders: return "bell"
        }
    }

    /// Sections whose content is a searchable list.
    var isSearchable: Bool {
        switch self {
        case .tasks, .projects, .playbooks, .owners, .tags: return true
        default: return false
        }
    }

    /// What the field says before you type.
    var searchPlaceholder: String { "Search \(title.lowercased())…" }

    /// The title under the active backend. Recurring unattended agents are
    /// flow’s “owners” and praxis’s “schedules” — the same pane, and calling it
    /// by the name the user’s CLI uses is the difference between recognising it
    /// and hunting for it.
    func title(_ capabilities: BackendCapabilities) -> String {
        self == .owners ? capabilities.recurringTitle : title
    }

    /// The rail for a backend: a pane whose backing concept does not exist is
    /// left out rather than shown permanently empty.
    static func visible(_ capabilities: BackendCapabilities) -> [Section] {
        allCases.filter { section in
            switch section {
            case .playbooks: return capabilities.playbooks
            case .owners: return capabilities.recurring
            default: return true
            }
        }
    }
}

/// A navigation destination a dashboard tile can route to.
enum NavTarget {
    case section(Section)
    case tasks(TaskFilter)
    case tag(String)
}

/// Popover root: icon rail + content pane (header with global search, the
/// active section view, and a footer).
struct MenuContentView: View {
    @ObservedObject var store: Store

    @State private var section: Section = .tasks
    @State private var query: String = ""
    @State private var taskFilter: TaskFilter = .inProgress
    /// Lifted out of TasksView so Enter-to-open can respect the visible order.
    @State private var taskSort: TaskSort = .priority
    /// Guard for a large batch: opening N tasks spawns N sessions.
    @State private var confirmingBulkOpen = false
    @FocusState private var searchFocused: Bool

    /// flow terminal backends ($FLOW_TERM values). flow-bar is a GUI app with
    /// no terminal env to detect from, so the user picks explicitly. (kitty is
    /// omitted: its `kitty @` remote control needs the instance's socket in
    /// $KITTY_LISTEN_ON, which a GUI/menubar launch doesn't have — so it can't
    /// be driven reliably from here.)
    static let terminalOptions: [(label: String, value: String)] = [
        ("zellij", "zellij"), ("iTerm2", "iterm"),
        ("Terminal.app", "terminal"), ("Warp", "warp"), ("Ghostty", "ghostty"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            pane
        }
        .frame(width: 520, height: 560)
        // On macOS 26 the popover gets a REAL material behind it, so the glass
        // samples the desktop. Below that, the original opaque fill — never the
        // dynamic system colors, which render translucent over the popover's
        // vibrancy on older SDKs. (See Theme.)
        .background {
            if Theme.isGlass {
                PopoverSurface()
            } else {
                Theme.bg
            }
        }
        .onAppear { prepareForOpen() }
        .onChange(of: store.openNonce) { prepareForOpen() }
        // Switching backend can retire the pane you are standing on (praxis has
        // no playbooks). Landing on a rail item that no longer exists would
        // leave the pane blank with no way back, so step to the list everyone
        // has.
        .onChange(of: store.backendKind) {
            guard !Section.visible(store.capabilities).contains(section) else { return }
            store.closePeek(); store.cancelCreate()
            section = .tasks
        }
        // A task's "Remind me" bell seeds a draft while the popover is open —
        // jump to the Reminders section so its compose form appears.
        .onChange(of: store.pendingReminderDraft?.id) { _, id in
            guard id != nil else { return }
            store.closePeek(); store.cancelCreate()
            section = .reminders
            store.loadReminderLinkTasks()
        }
    }

    /// Reset navigation to the In-progress tab and refresh — run on every
    /// popover open (the view is reused, so this is signalled via openNonce).
    private func prepareForOpen() {
        store.closePeek(); store.cancelCreate()
        // The popover is the browsing half of the app — ⌥Space is where you go to
        // search. Search is still on the rail, one click away.
        section = .tasks
        taskFilter = .inProgress
        taskSort = .priority
        confirmingBulkOpen = false
        query = ""
        // A notification tap sets pendingReminderID before opening — land on the
        // Reminders section (focused on that reminder) instead of In-progress.
        if store.pendingReminderID != nil {
            section = .reminders
            store.loadReminderLinkTasks()
        } else if let action = store.pendingPaletteAction {
            // The centered palette ran something that needs this window — a
            // section, a drill-in, the intake form. It closed; we carry it out.
            store.pendingPaletteAction = nil
            runPaletteAction(action)
        } else if store.pendingAttention {
            // The menubar icon was alerting, so that alert is why the popover
            // was opened — go straight to what is blocked. Cleared here rather
            // than on close: the flag describes this one opening.
            section = .inbox
            store.pendingAttention = false
        }
        // Data loading is driven by the AppDelegate (beginActiveRefresh) so it
        // only runs while the popover is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Section.visible(store.capabilities)) { s in
                Button {
                    store.closePeek(); store.cancelCreate()
                    section = s
                    onSectionChange(s)
                } label: {
                    Image(systemName: s.icon)
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(section == s ? Color.accentColor : .secondary)
                        .railSelection(isSelected: section == s)
                        .overlay(alignment: .topTrailing) {
                            if let n = railBadge(s), n > 0 {
                                Text("\(n)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Circle().fill(.red).scaleEffect(1.3))
                                    .offset(x: -2, y: 2)
                            }
                        }
                        // Make the whole cell clickable, not just the glyph.
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(s.title(store.capabilities))
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 48)
    }

    // MARK: Pane

    /// Whether something is covering the section pane.
    private var overlayShown: Bool { store.isCreating || store.peekedSlug != nil }

    /// **The section pane is always in the hierarchy, even while covered.**
    ///
    /// The brief peek and the intake form used to *replace* it, which destroyed
    /// the section view and every `@State` it owned. The visible symptom was
    /// that reading a playbook's brief and pressing Back returned you to the
    /// playbooks list rather than to the playbook you were in: `selected` had
    /// been thrown away with the view. Projects, Tags and Owners all had it too.
    ///
    /// Layering keeps that state alive. The covered pane is hidden and disabled
    /// rather than removed, so it cannot take clicks or hold the text cursor
    /// while something is on top of it.
    private var pane: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                if section.isSearchable {
                    searchBar
                }
                Divider()
                sectionView
                if section == .tasks && !store.selectedTaskSlugs.isEmpty {
                    Divider()
                    selectionBar
                }
                Divider()
                footer
            }
            .opacity(overlayShown ? 0 : 1)
            .disabled(overlayShown)
            .accessibilityHidden(overlayShown)

            if store.isCreating {
                // Task intake takes over the whole content pane (its own header).
                CreateView(store: store)
            } else if let slug = store.peekedSlug {
                // Brief peek takes over the whole content pane (its own header).
                TaskDetailView(store: store, slug: slug)
            }
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch section {
        case .dashboard: DashboardView(store: store) { navigate($0) }
        case .tasks:     TasksView(store: store, query: query, filter: $taskFilter, sort: $taskSort)
        case .inbox:     InboxView(store: store)
        case .projects:  ProjectsView(store: store, query: query)
        case .playbooks: PlaybooksView(store: store, query: query)
        case .owners:    OwnersView(store: store, query: query)
        case .tags:      TagsView(store: store, query: query)
        case .reminders: RemindersView(store: store)
        }
    }

    /// Red count badge on a rail icon: the Needs-you inbox, and due/overdue
    /// reminders.
    private func railBadge(_ s: Section) -> Int? {
        switch s {
        case .inbox:
            guard let m = store.metrics else { return nil }
            return m.questionCount + m.overdueCount
        case .reminders:
            let n = store.reminders.activeBadgeCount()
            return n > 0 ? n : nil
        default:
            return nil
        }
    }

    // MARK: Header / search / footer

    /// The tasks section is a single rail item but has status tabs, so its
    /// header reflects the active tab (e.g. "Archived") rather than "In progress".
    private var headerTitle: String {
        section == .tasks ? taskFilter.rawValue : section.title(store.capabilities)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section.icon).font(.system(size: 16)).foregroundStyle(.tint)
            Text(headerTitle).font(.system(size: 17, weight: .bold))
            Text(countLabel).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            if isActiveLoading { ProgressView().controlSize(.small) }
            Button(action: { section == .reminders ? store.beginReminderBlank() : store.beginCreate() }) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain).help(section == .reminders ? "New reminder" : "New task")
            Button(action: refreshActive) { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                .buttonStyle(.plain).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
            TextField(section.searchPlaceholder, text: $query)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($searchFocused)
                .onSubmit {
                    guard section == .tasks else { return }
                    // A non-empty selection wins: Enter commits the thing the
                    // user has been building, which the action bar makes visible.
                    if store.selectedTaskSlugs.isEmpty { switchToFirstTask() }
                    else { openSelected() }
                }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .glassSurface(cornerRadius: 7, fallback: Theme.legacyField)
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    /// Label for the terminal footer control — the picked backend, or a prompt.
    private var currentTerminalLabel: String {
        Self.terminalOptions.first { $0.value == store.terminalBackend }?.label ?? "Terminal"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                SwiftUI.Section("Flow Roots") {
                    ForEach(store.profiles) { p in
                        Button {
                            store.setActiveProfile(p.id)
                        } label: {
                            if p.id == store.activeProfileID {
                                Label(p.name, systemImage: "checkmark")
                            } else {
                                Text(p.name)
                            }
                        }
                    }
                }
                Divider()
                Button("Add Flow Root…") { store.addProfileViaPicker() }
                if store.activeProfileID != Profile.defaultID {
                    Button("Remove “\(store.activeProfile.name)”", role: .destructive) {
                        store.removeActiveProfile()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.system(size: 13))
                    Text(store.activeProfile.name).font(.system(size: 13))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Switch flow root")

            // Terminal backend picker — its own footer control, next to the root.
            Menu {
                ForEach(Self.terminalOptions, id: \.value) { opt in
                    Button {
                        store.terminalBackend = opt.value
                    } label: {
                        if store.terminalBackend == opt.value {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal").font(.system(size: 13))
                    Text(currentTerminalLabel).font(.system(size: 13))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Terminal backend — where tasks open")

            Spacer()

            updateOrVersion

            Button(action: { Store.openSettings() }) {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// Footer trailing item: the current version, or an Update button when a
    /// newer release is available (or a retry on failure).
    @ViewBuilder
    private var updateOrVersion: some View {
        switch store.updateStatus {
        case .installing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Button { store.installUpdate() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Update failed — retry")
                }
                .font(.system(size: 12)).foregroundStyle(.red)
            }
            .buttonStyle(.plain).help(msg)
        case .idle:
            if let up = store.availableUpdate, store.isManagedInstall {
                // Homebrew owns this install, so brew does the work — but it is
                // still one click, not a command to paste.
                Button { store.installUpdate() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                        Text("Update to v\(up.version)").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Runs “\(Updater.upgradeCommand)”. flow-bar quits, Homebrew "
                      + "rebuilds it for your macOS, and it reopens when it's done "
                      + "(about a minute).")
            } else if store.needsSDKRebuild {
                // Built against an older SDK than the OS we're on, so the UI is
                // rendering in compatibility mode. A rebuild fixes it.
                Button { store.copyToPasteboard(Updater.rebuildCommand) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 11))
                        Text("Rebuild for macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Built against the macOS \(AppInfo.buildSDK ?? "?") SDK. "
                      + "Copy “\(Updater.rebuildCommand)” to rebuild natively.")
            } else if let up = store.availableUpdate {
                Button { store.installUpdate() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                        Text("Update to v\(up.version)").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).help("Download and install v\(up.version)")
            } else {
                // The version is the one thing in the footer that can answer
                // "what changed?", so it links to the notes for exactly this
                // build rather than to a releases index you then have to search.
                Button {
                    NSWorkspace.shared.open(ReleaseLinks.url(forVersion: store.currentVersion))
                } label: {
                    Text("v\(store.currentVersion)")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("What's new in v\(store.currentVersion) — opens the release notes")
            }
        }
    }

    // MARK: Behavior

    private func jump(to s: Section) {
        section = s
        onSectionChange(s)
    }

    /// Route a dashboard tile to its destination — either a section, or the
    /// Tasks view with a specific status filter applied.
    private func navigate(_ target: NavTarget) {
        switch target {
        case .section(let s):
            jump(to: s)
        case .tasks(let f):
            taskFilter = f
            section = .tasks
            if f == .inProgress { store.refresh() } else { store.loadBrowse(status: f.status) }
        case .tag(let t):
            store.pendingTagDrill = t   // TagsView opens pre-drilled into this tag
            jump(to: .tags)
        }
    }

    /// Dispatch a palette row.
    ///
    /// Everything except `openTask` is navigation: the palette is a way *into*
    /// the section views, not a replacement for them. Drill-in targets are
    /// handed over as a `pending…` slug before the jump, the way the dashboard's
    /// tag tiles already do it — the destination view consumes it in `onAppear`
    /// and opens on that row instead of its list.
    private func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .openTask(let slug):
            // Same path as a click in any task list, ⌥-to-skip-prompts included.
            store.switchTo(slug)
        case .openTaskSkippingPrompts(let slug):
            store.switchTo(slug, skipPermissions: true)
        case .openBatch(let slugs):
            store.switchToAll(slugs)
        case .openProject(let slug):
            store.pendingProjectDrill = slug
            jump(to: .projects)
        case .openPlaybook(let slug):
            store.pendingPlaybookDrill = slug
            jump(to: .playbooks)
        case .openOwner(let slug):
            store.pendingOwnerDrill = slug
            jump(to: .owners)
        case .openTag(let tag):
            store.pendingTagDrill = tag
            jump(to: .tags)
        case .openReminder(let id):
            store.pendingReminderID = id
            jump(to: .reminders)
        case .section(let raw):
            // "backlog" is a filter on the Tasks pane rather than a pane of its
            // own, so it has no rail section to jump to.
            if raw == "backlog" { navigate(.tasks(.backlog)) }
            else if let s = Section(rawValue: raw) { jump(to: s) }
        case .releaseNotes:
            // This window has no document reader; the palette does. Sending the
            // published notes is the honest fallback.
            store.markReleaseNotesSeen()
            NSWorkspace.shared.open(ReleaseLinks.url(forVersion: store.currentVersion))
        case .newTask:
            store.beginCreate()
        case .newReminder:
            // Seeding the draft is enough: the root view already watches for
            // one and lands on Reminders with the compose form open.
            store.beginReminderBlank()
        case .refresh:
            store.refreshPalette()
            store.refreshMetrics()
        case .settings:
            Store.openSettings()
        }
    }

    private func onSectionChange(_ s: Section) {
        query = ""
        switch s {
        case .dashboard, .inbox, .playbooks, .projects, .owners, .tags: store.refreshMetrics()
        case .reminders: store.loadReminderLinkTasks()   // populate the link picker
        case .tasks:
            store.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    private func refreshActive() {
        switch section {
        case .tasks: store.refresh()
        default: store.refreshMetrics()
        }
    }

    private var isActiveLoading: Bool {
        switch section {
        case .tasks: return taskFilter == .inProgress ? store.isLoading : store.browseLoading
        default: return store.metricsLoading
        }
    }

    private var countLabel: String {
        switch section {
        case .tasks:
            let src = taskFilter == .inProgress ? store.tasks : store.browseTasks
            let total = src.count
            let shown = src.filtered(by: query).count
            return (query.isEmpty || shown == total) ? "\(total)" : "\(shown) of \(total)"
        case .inbox:
            guard let m = store.metrics else { return "" }
            let n = m.questionCount + m.overdueCount + m.waitingCount
            return n > 0 ? "\(n)" : ""
        default:
            return ""
        }
    }

    /// Open the first row Enter should act on.
    ///
    /// This used to hardcode `store.tasks` + `sortedByPriority()`, ignoring both
    /// the active filter and the sort — so Enter on the Done tab opened some
    /// unrelated in-progress task. Now it goes through the same `visible(...)`
    /// helper the list renders from, and skips rows `flow do` can't act on.
    private func switchToFirstTask() {
        let source = taskFilter == .inProgress ? store.tasks : store.browseTasks
        if let first = source.firstOpenable(
            query: query, sort: TasksView.coreSort(taskSort, taskFilter)) {
            store.switchTo(first.slug)
        }
    }

    /// Slugs currently visible under the active filter + search. Used to tell
    /// the user how many of their checks the search is hiding.
    private var visibleTaskSlugs: Set<String> {
        let source = taskFilter == .inProgress ? store.tasks : store.browseTasks
        return Set(source.filtered(by: query).map(\.slug))
    }

    /// Opening N tasks spawns N sessions, which is a much heavier action than
    /// the single click it inherits from — confirm once past this many.
    private static let bulkOpenConfirmThreshold = 5

    private func openSelected() {
        let batch = store.orderedSelection
        if batch.count > Self.bulkOpenConfirmThreshold && !confirmingBulkOpen {
            confirmingBulkOpen = true
            return
        }
        confirmingBulkOpen = false
        store.switchToAll(batch)
    }

    /// "N selected · M hidden by search — Clear — Open all".
    ///
    /// The hidden count is the load-bearing part: after re-searching, none of
    /// the ticked rows are on screen, and without this the user has no evidence
    /// their earlier checks survived. That reassurance is the feature.
    private var selectionBar: some View {
        let summary = selectionSummary(selected: store.selectedTaskSlugs,
                                       visibleSlugs: visibleTaskSlugs)
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
            Text("\(summary.total) selected")
                .font(.system(size: 12, weight: .medium))
            if summary.hidden > 0 {
                Text("· \(summary.hidden) hidden by search")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if confirmingBulkOpen {
                Text("Open \(summary.total) sessions?")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Button("Cancel") { confirmingBulkOpen = false }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open all") { openSelected() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            } else {
                Button("Clear") { store.clearSelection() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                Button("Open all (\(summary.total))") { openSelected() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}
