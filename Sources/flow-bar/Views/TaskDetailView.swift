import FlowBarCore
import SwiftUI

/// Inline brief peek: a task's brief + recent updates, shown over the pane with
/// a back button. Read-only. Content is markdown files (never flow.db); the
/// paths come from `flow show task` via `Store.peekBrief`.
struct TaskDetailView: View {
    @ObservedObject var store: Store
    let slug: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { store.closePeek() }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    Text("Back").font(.system(size: 14))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to list")

            Spacer()

            // Copy the whole peek (brief + all updates) to the clipboard.
            if let d = store.taskDetail, !d.clipboardText.isEmpty {
                Button(action: { copyBrief(d.clipboardText) }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the brief + updates to the clipboard")
            }

            // Remind me about this task — opens the reminder compose form
            // pre-linked to it.
            if let d = store.taskDetail {
                Button(action: { store.beginReminder(slug: d.slug, name: d.name) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bell").font(.system(size: 13))
                        Text("Remind").font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remind me about this task")
            }

            // Done/archived tasks have nothing to switch to — no Open action.
            if store.taskDetail?.canOpen == true {
                let sessions = store.taskDetail?.sessions ?? []
                // With more than one session on the task, Open alone cannot
                // say WHICH — so it becomes a split control: the button still
                // opens the obvious one, the menu names them. A single session
                // gets the plain button, because a menu of one is a menu that
                // only costs a click.
                if store.capabilities.multipleSessionsPerTask && sessions.count > 1 {
                    // A long-running task accumulates these — one real task
                    // offers 23 — and a 23-line menu is a wall rather than a
                    // choice. The most recent handful is what anyone actually
                    // resumes; the rest are named by `flowbar-smoke
                    // --sessions-for <slug>` rather than pretended away.
                    let shown = sessions.prefix(Self.sessionsInMenu)
                    let hidden = sessions.count - shown.count
                    Menu {
                        SwiftUI.Section("Resume a session") {
                            ForEach(shown) { s in
                                Button(Self.sessionLabel(s)) {
                                    store.switchTo(slug, skipPermissions: false,
                                                   destination: .session(s.id))
                                }
                            }
                            if hidden > 0 {
                                Button("\(hidden) older not shown") {}.disabled(true)
                            }
                        }
                        Divider()
                        Button("New session…") {
                            store.switchTo(slug, skipPermissions: false, destination: .fresh)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle").font(.system(size: 14))
                            Text("Open").font(.system(size: 14, weight: .medium))
                        }
                    } primaryAction: {
                        store.switchTo(slug)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Open the session this task was last worked in, "
                          + "or pick from its \(sessions.count) sessions")
                } else {
                    Button(action: { store.switchTo(slug) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle").font(.system(size: 14))
                            Text("Open").font(.system(size: 14, weight: .medium))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Switch to this task")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// How many sessions the Open menu lists before it stops.
    static let sessionsInMenu = 8

    /// One session, as a menu line: what it is about, how old it is, and
    /// whether it is on screen right now.
    ///
    /// The title carries the choice — it is the session's own, so two sessions
    /// on one task read as "discovery capture" vs "call documentation" rather
    /// than as two UUIDs. The age disambiguates two similar titles, and ● marks
    /// the one already running, since picking it focuses that tab instead of
    /// opening anything.
    static func sessionLabel(_ s: TaskSession) -> String {
        var line = s.live ? "● " : ""
        line += s.label
        if let started = s.started {
            line += "  —  \(RelativeAge.short(started, now: Date())) ago"
        }
        return line
    }

    @State private var copied = false
    @State private var slugCopied = false

    private func copyBrief(_ text: String) {
        write(text)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func copySlug(_ slug: String) {
        write(slug)
        slugCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            slugCopied = false
        }
    }

    private func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @ViewBuilder
    private var content: some View {
        if store.taskDetailLoading, store.taskDetail == nil {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = store.taskDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(d.name)
                        .font(.system(size: 17, weight: .bold))
                        .textSelection(.enabled)
                    // The slug is the one string you retype constantly (it's
                    // how every flow command names a task), so it gets its own
                    // copy button rather than relying on selecting the text.
                    HStack(spacing: 5) {
                        Text(d.slug)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(action: { copySlug(d.slug) }) {
                            Image(systemName: slugCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(slugCopied ? Color.green : Color.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(slugCopied ? "Copied" : "Copy the slug")
                    }

                    if d.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyNote("No brief written for this task yet.")
                    } else {
                        MarkdownText(Self.dropLeadingTitle(d.brief))
                    }

                    if !d.updates.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("RECENT UPDATES")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
                        ForEach(d.updates) { u in updateBlock(u) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            emptyNote("Couldn’t load this task’s brief.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func updateBlock(_ u: TaskUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(u.date)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(u.title)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            MarkdownText(Self.dropLeadingTitle(u.content))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Briefs and update notes conventionally start with a `# Title` line that
    /// repeats the name/date the peek already shows in its own header. Drop that
    /// leading H1 (and any blank lines after it) to avoid the duplicate title.
    static func dropLeadingTitle(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            lines.removeFirst()
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
    }
}
