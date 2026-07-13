import AppKit
import FlowBarCore
import SwiftUI

/// The Reminders section: a grouped list of user reminders (Overdue / Today /
/// Upcoming / Completed) plus an inline compose form. Reminders are standalone
/// or linked to a task; a linked reminder offers an **Open** button. A
/// notification tap lands here focused on the fired reminder.
struct RemindersView: View {
    @ObservedObject var store: Store

    // Compose form state (seeded from store.pendingReminderDraft).
    @State private var composing = false
    @State private var editingID: UUID?
    @State private var title = ""
    @State private var note = ""
    @State private var fireDate = Date().addingTimeInterval(3600)
    @State private var datePickerExpanded = false
    @State private var linkedTasks: [LinkedTask] = []
    @State private var linkPickerOpen = false
    @State private var taskSearch = ""
    // Link-picker filters.
    @State private var linkShowInProgress = true
    @State private var linkShowBacklog = true
    @State private var linkTagFilter: String?

    // The reminder a notification tapped — highlighted + scrolled to.
    @State private var focusID: UUID?
    // Which reminder is expanded to show its note + attached tasks.
    @State private var expandedID: UUID?

    var body: some View {
        Group {
            if composing {
                composeForm
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { consumeDraft(); consumeFocus() }
        .onChange(of: store.pendingReminderDraft?.id) { _ in consumeDraft() }
        .onChange(of: store.pendingReminderID) { _ in consumeFocus() }
    }

    // MARK: - List

    private var groups: ReminderGroups { store.reminders.group(now: Date()) }

    private var list: some View {
        VStack(spacing: 0) {
            if store.notificationsDenied { permissionBanner }
            if groups.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            bucket("Overdue", groups.overdue, tint: .red)
                            bucket("Today", groups.today, tint: Theme.accent)
                            bucket("Upcoming", groups.upcoming, tint: .secondary)
                            bucket("Completed", groups.completed, tint: .green)
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: focusID) { id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = focusID {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bucket(_ label: String, _ items: [Reminder], tint: Color) -> some View {
        if !items.isEmpty {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(items) { r in
                row(r)
                    .id(r.id)
                    .background(focusID == r.id ? Theme.accent.opacity(0.14) : .clear)
            }
        }
    }

    private func row(_ r: Reminder) -> some View {
        let canExpand = r.isLinked || (r.note?.isEmpty == false)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    r.isCompleted ? store.uncompleteReminder(id: r.id) : store.completeReminder(id: r.id)
                } label: {
                    Image(systemName: r.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(r.isCompleted ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help(r.isCompleted ? "Mark not done" : "Mark done")

                // Tapping the body expands the reminder to show its note +
                // attached tasks.
                Button { toggleExpand(r) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title.isEmpty ? "Reminder" : r.title)
                            .font(.system(size: 15, weight: .medium))
                            .strikethrough(r.isCompleted, color: .secondary)
                            .foregroundStyle(r.isCompleted ? Color.secondary : .primary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(fireLabel(r))
                                .font(.system(size: 12))
                                .foregroundStyle(r.isOverdue() ? .red : .secondary)
                            if r.isLinked {
                                HStack(spacing: 3) {
                                    Image(systemName: "list.bullet").font(.system(size: 10))
                                    Text(r.tasks.count == 1 ? r.tasks[0].slug : "\(r.tasks.count) tasks")
                                        .font(.system(size: 12)).lineLimit(1)
                                }
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if canExpand {
                    Image(systemName: expandedID == r.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                Menu {
                    if !r.isCompleted {
                        Button("Snooze 1 hour") { store.snoozeReminder(id: r.id, by: 3600) }
                        Button("Snooze 3 hours") { store.snoozeReminder(id: r.id, by: 3 * 3600) }
                        Button("Snooze to tomorrow 9am") { store.snoozeReminder(id: r.id, by: secondsUntilTomorrow9()) }
                        Button("Edit…") { beginEdit(r) }
                    }
                    Button("Delete", role: .destructive) { store.deleteReminder(id: r.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            if expandedID == r.id { expandedDetail(r) }
        }
        .contentShape(Rectangle())
    }

    /// Expanded reminder detail: full note + the attached tasks, each openable.
    private func expandedDetail(_ r: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = r.note, !n.isEmpty {
                Text(n).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.isLinked {
                Text("ATTACHED TASKS").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                ForEach(r.tasks) { t in
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet").font(.system(size: 10)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.slug).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if t.name != t.slug {
                                Text(t.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if !r.isCompleted {
                            Button { store.openLinkedTask(t) } label: { openLabel }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                                .help("Switch to this task")
                        }
                    }
                }
            }
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.bottom, 8)
    }

    private func toggleExpand(_ r: Reminder) {
        guard r.isLinked || (r.note?.isEmpty == false) else { return }
        expandedID = (expandedID == r.id) ? nil : r.id
    }

    private var openLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right.circle").font(.system(size: 12))
            Text("Open").font(.system(size: 12, weight: .medium))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No reminders yet").font(.system(size: 15)).foregroundStyle(.secondary)
            Text("Use ＋ above, or the bell on a task, to add one.")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Notifications are off — reminders won't alert you.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Enable") { openNotificationSettings() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.tile)
    }

    // MARK: - Compose form

    private var composeForm: some View {
        VStack(spacing: 0) {
            composeHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    labeled("Title", error: title.trimmingCharacters(in: .whitespaces).isEmpty ? "required" : nil) {
                        TextField("What should I remind you about?", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("When", error: fireDate <= Date() ? "pick a future time" : nil) {
                        VStack(alignment: .leading, spacing: 8) {
                            // Zero-padded, gap-free summary; tap to reveal a calendar.
                            Button { withAnimation { datePickerExpanded.toggle() } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(.secondary)
                                    Text(fireDateDisplay).font(.system(size: 13))
                                    Spacer()
                                    Image(systemName: datePickerExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if datePickerExpanded {
                                VStack(alignment: .leading, spacing: 8) {
                                    DatePicker("", selection: $fireDate, displayedComponents: [.date])
                                        .datePickerStyle(.graphical).labelsHidden()
                                    HStack(spacing: 8) {
                                        Text("Time").font(.system(size: 12)).foregroundStyle(.secondary)
                                        // Typeable HH:MM field (the graphical style's analog
                                        // clock is awkward to set precisely).
                                        DatePicker("", selection: $fireDate, displayedComponents: [.hourAndMinute])
                                            .datePickerStyle(.field).labelsHidden().fixedSize()
                                    }
                                }
                                .padding(8).background(Theme.tile)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            HStack(spacing: 6) {
                                quickFill("In 1h", .inOneHour)
                                quickFill("This evening", .thisEvening)
                                quickFill("Tomorrow 9am", .tomorrowMorning)
                            }
                        }
                    }
                    labeled("Note", hint: "optional") {
                        TextEditor(text: $note)
                            .font(.system(size: 13))
                            .frame(height: 70)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(Theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    labeled("Linked task", hint: "optional") { taskLink }
                }
                .padding(14)
            }
        }
    }

    private var composeHeader: some View {
        HStack(spacing: 6) {
            Button { composing = false } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 13))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Back")
            Spacer()
            Text(editingID == nil ? "New reminder" : "Edit reminder")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(editingID == nil ? "Add" : "Save") { save() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canSave ? Theme.accent : Color.secondary)
                .disabled(!canSave)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var taskLink: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Selected tasks as removable chips (left-packed, wrapping).
            if !linkedTasks.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(linkedTasks) { t in
                        Button { linkedTasks.removeAll { $0.slug == t.slug } } label: {
                            HStack(spacing: 3) {
                                Text(t.slug).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 8))
                            }
                            .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accent).foregroundStyle(.white).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // Dropdown toggle — same idiom as CreateView's tag picker.
            Button { linkPickerOpen.toggle() } label: {
                HStack {
                    Text(linkedTasks.isEmpty ? "Link tasks…" : "\(linkedTasks.count) linked · add more")
                        .foregroundStyle(linkedTasks.isEmpty ? Color.secondary : Color.primary)
                    Spacer()
                    Image(systemName: linkPickerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if linkPickerOpen {
                VStack(spacing: 0) {
                    // Status + tag filters.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            filterChip("In progress", on: linkShowInProgress) { linkShowInProgress.toggle() }
                            filterChip("Backlog", on: linkShowBacklog) { linkShowBacklog.toggle() }
                            Spacer(minLength: 0)
                        }
                        if !linkTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(linkTags, id: \.self) { tag in
                                        filterChip("#\(tag)", on: linkTagFilter == tag) {
                                            linkTagFilter = (linkTagFilter == tag) ? nil : tag
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    Divider()
                    TextField("filter tasks…", text: $taskSearch)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    Divider()
                    let pool = filteredLinkTasks
                    if pool.isEmpty {
                        Text("no matching tasks").font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(pool) { t in
                                    let on = linkedTasks.contains { $0.slug == t.slug }
                                    Button { toggleLinkedTask(t) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 12))
                                                .foregroundStyle(on ? Theme.accent : .secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(t.slug).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                                if !t.name.isEmpty {
                                                    Text(t.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                            }
                                            Spacer(minLength: 4)
                                            StatusPill(status: t.status)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                }
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func toggleLinkedTask(_ t: FlowTask) {
        if let i = linkedTasks.firstIndex(where: { $0.slug == t.slug }) {
            linkedTasks.remove(at: i)
        } else {
            linkedTasks.append(LinkedTask(slug: t.slug, name: t.name, profileID: store.activeProfileID))
            if title.trimmingCharacters(in: .whitespaces).isEmpty {
                title = t.name.isEmpty ? t.slug : t.name
            }
        }
    }

    /// Distinct tags across the linkable tasks (for the filter chip row).
    private var linkTags: [String] {
        Set(store.reminderLinkTasks.flatMap { $0.tagList }).sorted()
    }

    private var filteredLinkTasks: [FlowTask] {
        let q = taskSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return store.reminderLinkTasks.filter { t in
            let statusOK = (t.status == "in-progress" && linkShowInProgress)
                || (t.status == "backlog" && linkShowBacklog)
            let tagOK = linkTagFilter == nil || t.tagList.contains(linkTagFilter!)
            let textOK = q.isEmpty || t.slug.lowercased().contains(q) || t.name.lowercased().contains(q)
            return statusOK && tagOK && textOK
        }
    }

    private func filterChip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(on ? Theme.accent : Theme.chip)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A labeled field with an optional red error or grey hint — matches
    /// CreateView so the two forms read the same.
    private func labeled(_ title: String, error: String? = nil, hint: String? = nil,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                if let error {
                    Text(error).font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
                } else if let hint {
                    Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func quickFill(_ label: String, _ preset: ReminderPreset) -> some View {
        Button(label) {
            if let d = preset.date(from: Date()), d > Date() { fireDate = d }
            else { fireDate = Date().addingTimeInterval(3600) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.chip).clipShape(Capsule())
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && fireDate > Date()
    }

    // MARK: - Actions

    private func consumeDraft() {
        guard let d = store.pendingReminderDraft else { return }
        title = d.title
        note = d.note
        fireDate = d.fireDate
        linkedTasks = d.tasks
        editingID = nil
        linkPickerOpen = false
        taskSearch = ""
        composing = true
        store.pendingReminderDraft = nil
    }

    private func consumeFocus() {
        guard let id = store.pendingReminderID else { return }
        focusID = id
        expandedID = id   // auto-expand so its attached tasks are visible
        composing = false
        store.pendingReminderID = nil
    }

    private func beginEdit(_ r: Reminder) {
        title = r.title
        note = r.note ?? ""
        fireDate = r.fireDate
        linkedTasks = r.tasks
        editingID = r.id
        linkPickerOpen = false
        taskSearch = ""
        composing = true
    }

    private func save() {
        guard canSave else { return }
        let existing = editingID.flatMap { id in store.reminders.first { $0.id == id } }
        let r = Reminder(
            id: editingID ?? UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            note: note.isEmpty ? nil : note,
            fireDate: fireDate,
            createdAt: existing?.createdAt ?? Date(),
            completedAt: nil,
            tasks: linkedTasks)
        if editingID != nil { store.updateReminder(r) } else { store.addReminder(r) }
        composing = false
        resetFields()
    }

    private func resetFields() {
        title = ""; note = ""; linkedTasks = []
        editingID = nil; linkPickerOpen = false; taskSearch = ""
    }

    // MARK: - Helpers

    /// Zero-padded, gap-free summary of the compose fire date (no confusing
    /// single-digit gaps like the native field's " 9/ 7").
    private var fireDateDisplay: String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM dd, yyyy 'at' HH:mm"
        return df.string(from: fireDate)
    }

    private func fireLabel(_ r: Reminder) -> String {
        let df = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(r.fireDate) {
            df.dateFormat = "'Today' HH:mm"
        } else if cal.isDateInTomorrow(r.fireDate) {
            df.dateFormat = "'Tomorrow' HH:mm"
        } else if cal.isDateInYesterday(r.fireDate) {
            df.dateFormat = "'Yesterday' HH:mm"
        } else {
            df.dateFormat = "MMM d, HH:mm"
        }
        let s = df.string(from: r.fireDate)
        return r.isOverdue() ? "Overdue · \(s)" : s
    }

    private func secondsUntilTomorrow9() -> TimeInterval {
        let target = ReminderPreset.tomorrowMorning.date(from: Date()) ?? Date().addingTimeInterval(24 * 3600)
        return max(60, target.timeIntervalSinceNow)
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
