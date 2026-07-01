import FlowBarCore
import SwiftUI

/// App sections, shown as the left icon rail.
enum Section: String, CaseIterable, Identifiable {
    case dashboard, tasks, inbox, playbooks, projects, owners
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .tasks: return "In progress"
        case .inbox: return "Needs you"
        case .playbooks: return "Playbooks"
        case .projects: return "Projects"
        case .owners: return "Owners"
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
        }
    }

    /// Sections whose content is a searchable list.
    var isSearchable: Bool {
        switch self {
        case .tasks, .projects, .playbooks, .owners: return true
        default: return false
        }
    }
}

/// A navigation destination a dashboard tile can route to.
enum NavTarget {
    case section(Section)
    case tasks(TaskFilter)
}

/// Popover root: icon rail + content pane (header with global search, the
/// active section view, and a footer).
struct MenuContentView: View {
    @ObservedObject var store: Store

    @State private var section: Section = .tasks
    @State private var query: String = ""
    @State private var taskFilter: TaskFilter = .inProgress
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
        // Explicit OPAQUE fill (see Theme) — never the dynamic system colors,
        // which render translucent over the popover's vibrancy on older SDKs.
        .background(Theme.bg)
        .onAppear { prepareForOpen() }
        .onChange(of: store.openNonce) { _ in prepareForOpen() }
    }

    /// Reset navigation to the In-progress tab and refresh — run on every
    /// popover open (the view is reused, so this is signalled via openNonce).
    private func prepareForOpen() {
        store.closePeek()
        section = .tasks
        taskFilter = .inProgress
        query = ""
        // Data loading is driven by the AppDelegate (beginActiveRefresh) so it
        // only runs while the popover is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Section.allCases) { s in
                Button {
                    store.closePeek()
                    section = s
                    onSectionChange(s)
                } label: {
                    Image(systemName: s.icon)
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(section == s ? Color.accentColor.opacity(0.2) : .clear)
                        .foregroundStyle(section == s ? Color.accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
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
                .help(s.title)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 48)
    }

    // MARK: Pane

    @ViewBuilder
    private var pane: some View {
        if let slug = store.peekedSlug {
            // Brief peek takes over the whole content pane (its own header).
            TaskDetailView(store: store, slug: slug)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if section.isSearchable {
                    searchBar
                }
                Divider()
                sectionView
                Divider()
                footer
            }
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch section {
        case .dashboard: DashboardView(store: store) { navigate($0) }
        case .tasks:     TasksView(store: store, query: query, filter: $taskFilter)
        case .inbox:     InboxView(store: store)
        case .projects:  ProjectsView(store: store, query: query)
        case .playbooks: PlaybooksView(store: store, query: query)
        case .owners:    OwnersView(store: store, query: query)
        }
    }

    /// Red count badge on a rail icon (currently the Needs-you inbox).
    private func railBadge(_ s: Section) -> Int? {
        guard s == .inbox, let m = store.metrics else { return nil }
        return m.questionCount + m.overdueCount
    }

    // MARK: Header / search / footer

    /// The tasks section is a single rail item but has status tabs, so its
    /// header reflects the active tab (e.g. "Archived") rather than "In progress".
    private var headerTitle: String {
        section == .tasks ? taskFilter.rawValue : section.title
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section.icon).font(.system(size: 16)).foregroundStyle(.tint)
            Text(headerTitle).font(.system(size: 17, weight: .bold))
            Text(countLabel).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            if isActiveLoading { ProgressView().controlSize(.small) }
            Button(action: refreshActive) { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                .buttonStyle(.plain).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
            TextField("Search \(headerTitle.lowercased())…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($searchFocused)
                .onSubmit { if section == .tasks { switchToFirstTask() } }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.bottom, 6)
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
                Divider()
                Menu("Terminal") {
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
                }
                Toggle("Monochrome icon", isOn: $store.monochromeIcon)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.system(size: 13))
                    Text(store.activeProfile.name).font(.system(size: 13))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Switch flow root")

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
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
        }
    }

    private func onSectionChange(_ s: Section) {
        query = ""
        switch s {
        case .dashboard, .inbox, .playbooks, .projects, .owners: store.refreshMetrics()
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

    private func switchToFirstTask() {
        if let first = store.tasks.filtered(by: query).sortedByPriority().first {
            store.switchTo(first.slug)
        }
    }
}
