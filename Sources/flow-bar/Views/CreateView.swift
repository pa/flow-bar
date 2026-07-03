import FlowBarCore
import SwiftUI

/// Task intake (no LLM). Per-field validation mirrors flow's rules: slug is the
/// primary key (must be unique + kebab-case so it's a usable ref), a new
/// project must be created before the task can reference it, and a work_dir
/// must exist unless mkdir is on.
struct CreateView: View {
    @ObservedObject var store: Store

    // Task
    @State private var name = ""
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var suppressSlugEdit = false
    @State private var priority = "medium"
    @State private var selectedTags: Set<String> = []
    @State private var tagsExpanded = false
    @State private var tagSearch = ""
    @State private var due = ""
    @State private var workDir = ""
    @State private var mkdir = false
    @State private var brief = CreateView.briefTemplate

    // Project selection: "" = none/floating, "__new__" = create new, else a slug.
    @State private var projectSel = ""
    @State private var npName = ""
    @State private var npSlug = ""
    @State private var npSlugEdited = false
    @State private var suppressNpSlugEdit = false
    @State private var npWorkDir = ""
    @State private var npMkdir = true

    static let briefTemplate = "## What\n\n## Why\n\n## Done when\n- [ ] \n"
    private var isNewProject: Bool { projectSel == "__new__" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    // MARK: validation

    private func kebabOK(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
    private func dirExists(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        let path = (p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    private func slugError(_ s: String, existing: Set<String>) -> String? {
        if s.isEmpty { return nil }
        if !kebabOK(s) { return "lowercase letters, numbers, dashes only" }
        if existing.contains(s) { return "already exists" }
        return nil
    }
    private var taskSlugError: String? { slugError(slug, existing: store.existingTaskSlugs) }
    private var npSlugError: String? { slugError(npSlug, existing: store.existingProjectSlugs) }
    private var workDirError: String? {
        let p = workDir.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || mkdir { return nil }
        return dirExists(p) ? nil : "doesn’t exist — enable mkdir"
    }
    private var npWorkDirError: String? {
        let p = npWorkDir.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || npMkdir { return nil }
        return dirExists(p) ? nil : "doesn’t exist — enable mkdir"
    }
    private var canCreate: Bool {
        guard !trimmedName.isEmpty, !slug.isEmpty, taskSlugError == nil,
              workDirError == nil, !store.creatingBusy else { return false }
        if isNewProject {
            guard !npName.trimmingCharacters(in: .whitespaces).isEmpty,
                  !npSlug.isEmpty, npSlugError == nil,
                  !npWorkDir.trimmingCharacters(in: .whitespaces).isEmpty,
                  npWorkDirError == nil else { return false }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    labeled("Name", error: trimmedName.isEmpty ? "required" : nil) {
                        TextField("What needs doing?", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: name) { _ in
                                if !slugEdited { suppressSlugEdit = true; slug = slugify(name) }
                            }
                    }
                    labeled("Slug", error: taskSlugError) {
                        TextField("slug", text: $slug)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: slug) { _ in
                                if suppressSlugEdit { suppressSlugEdit = false } else { slugEdited = true }
                            }
                    }
                    labeled("Project") {
                        Picker("", selection: $projectSel) {
                            Text("None (floating)").tag("")
                            ForEach(store.pickerProjects) { p in Text(p.name).tag(p.slug) }
                            Text("＋ New project…").tag("__new__")
                        }
                        .labelsHidden()
                    }
                    if isNewProject { newProjectFields }

                    labeled("Priority") {
                        prioritySegments
                    }
                    labeled("Tags", hint: "tap to toggle, or add your own") {
                        tagsPicker
                    }
                    labeled("Due", hint: "optional · friday · 2026-07-10 · +3d") {
                        TextField("", text: $due).textFieldStyle(.roundedBorder)
                    }
                    labeled("Work dir", error: workDirError,
                            hint: workDirError == nil ? "optional — inherits project, else auto" : nil) {
                        workDirField($workDir, $mkdir, "~/dev/…")
                    }
                    labeled("Brief") {
                        TextEditor(text: $brief)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(Theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if let e = store.createError {
                        Text(e).font(.system(size: 11)).foregroundStyle(.red)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
    }

    private var normalizedSearchTag: String {
        tagSearch.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
    }
    private var filteredTags: [String] {
        let q = normalizedSearchTag
        return q.isEmpty ? store.pickerTags : store.pickerTags.filter { $0.contains(q) }
    }
    private var canAddSearchTag: Bool {
        let t = normalizedSearchTag
        return !t.isEmpty && !store.pickerTags.contains(t) && !selectedTags.contains(t)
    }

    /// Searchable multi-select dropdown — scales to any number of tags.
    private var tagsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Selected tags as removable chips, left-packed and wrapping.
            if !selectedTags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(selectedTags.sorted(), id: \.self) { tag in
                        Button { selectedTags.remove(tag) } label: {
                            HStack(spacing: 3) {
                                Text("#\(tag)"); Image(systemName: "xmark").font(.system(size: 8))
                            }
                            .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accent).foregroundStyle(.white).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // Dropdown toggle.
            Button { tagsExpanded.toggle() } label: {
                HStack {
                    Text(selectedTags.isEmpty ? "Select tags…" : "\(selectedTags.count) selected")
                        .foregroundStyle(selectedTags.isEmpty ? Color.secondary : Color.primary)
                    Spacer()
                    Image(systemName: tagsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Expanded: search + scrollable checklist + add-new.
            if tagsExpanded {
                VStack(spacing: 0) {
                    TextField("filter or add a tag…", text: $tagSearch)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .onSubmit { if canAddSearchTag { addSearchTag() } }
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if canAddSearchTag {
                                Button(action: addSearchTag) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.accent)
                                        Text("Add “#\(normalizedSearchTag)”").font(.system(size: 12))
                                        Spacer()
                                    }.contentShape(Rectangle()).padding(.horizontal, 8).padding(.vertical, 5)
                                }.buttonStyle(.plain)
                            }
                            ForEach(filteredTags, id: \.self) { tag in
                                Button { toggleTag(tag) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: selectedTags.contains(tag) ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 11))
                                            .foregroundStyle(selectedTags.contains(tag) ? Theme.accent : .secondary)
                                        Text("#\(tag)").font(.system(size: 12))
                                        Spacer()
                                    }.contentShape(Rectangle()).padding(.horizontal, 8).padding(.vertical, 5)
                                }.buttonStyle(.plain)
                            }
                            if filteredTags.isEmpty && !canAddSearchTag {
                                Text("no tags").font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// A work-dir text field + mkdir toggle, with directory autocomplete under it.
    @ViewBuilder
    private func workDirField(_ text: Binding<String>, _ mkdirFlag: Binding<Bool>, _ placeholder: String) -> some View {
        HStack {
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            Toggle("mkdir", isOn: mkdirFlag).toggleStyle(.checkbox).font(.system(size: 11))
        }
        let suggestions = dirSuggestions(text.wrappedValue)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { s in
                    Button { text.wrappedValue = (s as NSString).abbreviatingWithTildeInPath } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text((s as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                            Spacer()
                        }
                        .contentShape(Rectangle()).padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Up to 6 existing subdirectories matching the typed path (for autocomplete).
    private func dirSuggestions(_ input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let ns = expanded as NSString
        let parent = expanded.hasSuffix("/") ? String(expanded.dropLast()) : ns.deletingLastPathComponent
        let prefix = expanded.hasSuffix("/") ? "" : ns.lastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
              let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") && (prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased())) }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: dir + "/" + $0, isDirectory: &d) && d.boolValue }
            .sorted()
            .prefix(6)
            .map { dir + "/" + $0 }
    }

    /// Custom segmented control (explicit Theme colors) — the native
    /// Picker(.segmented) renders differently across macOS SDKs (CI vs local),
    /// so we hardcode colors, exactly like the Tasks status tabs.
    private var prioritySegments: some View {
        HStack(spacing: 2) {
            ForEach([("High", "high"), ("Medium", "medium"), ("Low", "low")], id: \.1) { label, value in
                Button { priority = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: priority == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(priority == value ? Color.white : Color(.sRGB, white: 0.62, opacity: 1))
                        .background(priority == value ? Theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(Theme.track).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toggleTag(_ t: String) {
        if selectedTags.contains(t) { selectedTags.remove(t) } else { selectedTags.insert(t) }
    }
    private func addSearchTag() {
        let t = normalizedSearchTag
        guard !t.isEmpty else { return }
        selectedTags.insert(t)
        tagSearch = ""
    }

    private var newProjectFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("New project name", error: npName.trimmingCharacters(in: .whitespaces).isEmpty ? "required" : nil) {
                TextField("Project name", text: $npName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: npName) { _ in
                        if !npSlugEdited { suppressNpSlugEdit = true; npSlug = slugify(npName) }
                    }
            }
            labeled("Project slug", error: npSlugError) {
                TextField("project-slug", text: $npSlug)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: npSlug) { _ in
                        if suppressNpSlugEdit { suppressNpSlugEdit = false } else { npSlugEdited = true }
                    }
            }
            labeled("Project work dir",
                    error: npWorkDir.trimmingCharacters(in: .whitespaces).isEmpty ? "required" : npWorkDirError) {
                workDirField($npWorkDir, $npMkdir, "~/dev/project")
            }
        }
        .padding(10)
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { store.cancelCreate() }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Cancel").font(.system(size: 13))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Cancel")
            Spacer()
            Text("New task").font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.creatingBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: create) {
                    Text("Create").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canCreate ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain).disabled(!canCreate).help("Create task")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func create() {
        let tags = Array(selectedTags)
        let newProject: (name: String, slug: String, workDir: String, mkdir: Bool)? =
            isNewProject ? (npName.trimmingCharacters(in: .whitespaces), npSlug,
                            npWorkDir.trimmingCharacters(in: .whitespaces), npMkdir) : nil
        let existing: String? = (!isNewProject && !projectSel.isEmpty) ? projectSel : nil
        store.createTask(name: trimmedName, slug: slug, existingProject: existing, newProject: newProject,
                         priority: priority, tags: tags, due: due.trimmingCharacters(in: .whitespaces),
                         workDir: workDir.trimmingCharacters(in: .whitespaces), mkdir: mkdir, brief: brief)
    }

    /// A labeled field with an optional red error or grey hint under the title.
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
}
