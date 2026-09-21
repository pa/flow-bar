import Foundation

/// Everything a row can do, as a list.
///
/// **Why this exists at all.** The footer used to name every key at once, which
/// meant it outgrew the window: first the hints were cut to fit (so which keys
/// existed depended on how wide the panel was), then wrapped to two rows. Both
/// are workarounds for listing N things in a space that holds two.
///
/// Raycast's answer is structural — the footer shows the **primary action** and
/// `⌘K` for the rest, so it never has to choose. This type is that "rest": one
/// list, built in one place, which is also what stops the panel and the
/// popover's right-click menu drifting apart.
public enum PaletteActions {

    /// One entry in the ⌘K panel.
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        /// How to do it without opening this panel, when there is a way.
        public var shortcut: String?
        public var action: PaletteAction
        /// Shown first and separated — it is what ↵ already does.
        public var isPrimary: Bool

        public init(id: String, title: String, shortcut: String? = nil,
                    action: PaletteAction, isPrimary: Bool = false) {
            self.id = id
            self.title = title
            self.shortcut = shortcut
            self.action = action
            self.isPrimary = isPrimary
        }
    }

    /// What the row is currently part of, and where it is being asked from —
    /// facts the item itself can't carry because they live in the Store or in
    /// the palette's navigation.
    public struct Context: Sendable {
        public var isPinned: Bool
        public var isInBatch: Bool
        public var batchCount: Int
        public var batch: [String]
        /// True when the brief for this task is already on screen.
        ///
        /// An action list that offers to take you where you already are is
        /// noise, and worse, it makes the reader doubt the rest of the list.
        public var isViewingBrief: Bool

        public init(isPinned: Bool = false, isInBatch: Bool = false,
                    batchCount: Int = 0, batch: [String] = [],
                    isViewingBrief: Bool = false) {
            self.isPinned = isPinned
            self.isInBatch = isInBatch
            self.batchCount = batchCount
            self.batch = batch
            self.isViewingBrief = isViewingBrief
        }
    }

    /// The actions for a row, primary first.
    public static func list(for item: PaletteItem, context: Context = Context()) -> [Entry] {
        var out: [Entry] = []

        switch item.action {
        case .openTask(let slug), .openTaskSkippingPrompts(let slug):
            // **The primary entry is whatever ↵ actually does**, which is not
            // always "open this row": once a batch is selected, ↵ opens the
            // batch. Listing a plain "Open ↵" *and* a separate "Open all 3
            // selected" said the same key did two different things and gave the
            // batch a second, keyless way to be opened — one action wearing two
            // names. Open already means "open what is selected", one or many;
            // the only genuinely distinct thing is opening *just* this row
            // while a batch exists, and that is what the secondary entry says.
            // **`⌥↵` always opens whatever `↵` opens.** With a batch selected
            // the two were describing different things — "Open 8 selected" over
            // a bare "Open, skipping permission prompts" — and nothing on the
            // row said which the skip applied to. The pair moves together: when
            // there is a batch they are both the batch, when there is not they
            // are both this task.
            if context.batchCount > 0 {
                let n = context.batchCount
                out.append(Entry(id: "open", title: "Open \(n) selected",
                                 shortcut: "↵", action: .openBatch(context.batch),
                                 isPrimary: true))
                // No liveness test here: a batch is a mix, and the flag is
                // inert on whichever of them `flow do` answers by focusing a
                // tab that is already running. Suppressing it would take it
                // away from the ones it does reach.
                out.append(Entry(id: "open-skip",
                                 title: "Open \(n) selected, skipping permission prompts",
                                 shortcut: "⌥↵",
                                 action: .openBatchSkippingPrompts(context.batch)))
            } else {
                out.append(Entry(id: "open", title: "Open", shortcut: "↵",
                                 action: .openTask(slug), isPrimary: true))
                // Only where it can do anything: on a live task `flow do`
                // focuses the running tab and returns before building a command
                // line, so the flag never reaches the harness.
                if !item.hasLiveSession {
                    out.append(Entry(id: "open-skip",
                                     title: "Open, skipping permission prompts",
                                     shortcut: "⌥↵", action: .openTaskSkippingPrompts(slug)))
                }
            }
            if !context.isViewingBrief {
                out.append(Entry(id: "brief", title: "View brief", shortcut: "→",
                                 action: .openTask(slug)))   // the panel pushes the route
            }
            if context.isPinned {
                out.append(Entry(id: "pin", title: "Remove from jump list",
                                 shortcut: "⌘J", action: .togglePin(slug)))
            } else if item.isPinnable {
                out.append(Entry(id: "pin", title: "Add to jump list",
                                 shortcut: "⌘J", action: .togglePin(slug)))
            }
            out.append(Entry(id: "batch",
                             title: context.isInBatch ? "Remove from batch" : "Add to batch",
                             shortcut: "⌘↵", action: .toggleBatch(slug)))
            out.append(Entry(id: "copy", title: "Copy slug", shortcut: "⌘C",
                             action: .copy(slug)))
            out.append(Entry(id: "copy-brief", title: "Copy brief and notes",
                             action: .copyBrief(slug)))
            if let project = item.project {
                out.append(Entry(id: "copy-project", title: "Copy project name",
                                 action: .copy(project)))
            }
            if !item.tags.isEmpty {
                out.append(Entry(id: "copy-tags",
                                 title: item.tags.count == 1 ? "Copy tag" : "Copy tags",
                                 action: .copy(item.tags.map { "#\($0)" }
                                     .joined(separator: " "))))
            }

        case .openProject, .openPlaybook, .openOwner, .openTag:
            out.append(Entry(id: "enter", title: "Show contents", shortcut: "↵",
                             action: item.action, isPrimary: true))

        default:
            out.append(Entry(id: "run", title: "Run", shortcut: "↵",
                             action: item.action, isPrimary: true))
        }
        return out
    }

    /// The app itself, rather than the row in front of you.
    ///
    /// **Two menus, and the split is the object each one acts on.** `⌘K` acts
    /// on the selected row; this acts on flow-bar. Mixing them would put
    /// "Settings…" in a list whose every other line is about one task.
    ///
    /// **Two entries, and neither is a verb about your work.** Refresh was here
    /// and is gone: it acts on the data, not on the app, and the palette already
    /// refreshes on every open. What is left is the two things you go looking
    /// for and cannot otherwise find.
    ///
    /// These are the same actions the `@` command list already carries, on
    /// purpose: that is the keyboard route to them, and this is the mouse one.
    /// Before it existed there was no way to *find* Settings — you had to
    /// already know to type it, which is not a thing a settings screen can
    /// assume about the person looking for it.
    public static func appMenu() -> [Entry] {
        [
            Entry(id: "app-whats-new", title: "What's new", action: .releaseNotes),
            Entry(id: "app-settings", title: "Settings…", action: .settings),
        ]
    }
}

/// How a chord is drawn: one cap per key a hand presses.
///
/// **`⌘K` is two caps, not one chip.** Set as a single chip it reads as one key
/// with a strange name; split, it says what the hands do — which is the whole
/// job of a footer nobody reads twice. A word like `esc` is one physical key
/// and must survive whole, so the split is per-character except for a run of
/// ASCII letters.
public enum KeyCaps {
    public static func split(_ chord: String) -> [String] {
        if chord.count > 1, chord.allSatisfy({ $0.isLetter && $0.isASCII }) { return [chord] }
        return chord.map(String.init)
    }
}
