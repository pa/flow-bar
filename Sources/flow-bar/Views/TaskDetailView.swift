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

            // Done/archived tasks have nothing to switch to — no Open action.
            if store.taskDetail?.canOpen == true {
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
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @State private var copied = false

    private func copyBrief(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
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
                    Text(d.slug)
                        .font(.system(size: 13)).foregroundStyle(.secondary)

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

/// Minimal, dependency-free markdown renderer sufficient for flow briefs/updates:
/// headings (#, ##, ###), bullets, task checkboxes, and inline emphasis/code.
/// (macOS 13's SwiftUI has no block-markdown view; full engines are overkill
/// for a menubar peek.) Inline styling uses AttributedString's markdown parser.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
        .textSelection(.enabled)
    }

    private var lines: [String] { source.components(separatedBy: "\n") }

    @ViewBuilder
    private func row(for raw: String) -> some View {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if line.isEmpty {
            Spacer().frame(height: 3)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 3)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 3)
        } else if let box = checkbox(line) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: box.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(box.done ? Theme.accent : .secondary)
                inline(box.text)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: 15)).foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }
        } else {
            inline(line)
        }
    }

    /// "- [x] text" / "- [ ] text" -> (done, text); nil if not a checkbox.
    private func checkbox(_ line: String) -> (done: Bool, text: String)? {
        for (prefix, done) in [("- [x] ", true), ("- [X] ", true), ("- [ ] ", false)] {
            if line.hasPrefix(prefix) { return (done, String(line.dropFirst(prefix.count))) }
        }
        return nil
    }

    /// Render one line's inline markdown (bold/italic/code), preserving text.
    private func inline(_ text: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
