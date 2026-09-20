import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Holds a weak reference to the live text field so the window controller can
/// hand it first responder on every open. A `@FocusState` can't be reached from
/// AppKit, and the panel is shown by AppKit.
@MainActor
final class PaletteFocus {
    weak var field: NSTextField?

    func take() {
        guard let field else { return }
        field.window?.makeFirstResponder(field)
        // Put the caret at the end of whatever is there (normally nothing).
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }
}

/// The palette's one text field — an `NSTextField`, not SwiftUI's `TextField`.
///
/// **This is the whole keyboard design, and the reason it can work this time.**
/// Keyboard navigation was removed from this app once already (`1e5cb4e`: "it
/// produced more bugs than value"), and that version was a cursor bolted onto a
/// multi-pane mouse-first UI — rail zones, a router, a tree, and SwiftUI focus
/// being moved between them. Here there is exactly one first responder that
/// never changes, and arrow keys arrive as `doCommandBy` selectors on the field
/// itself. Nothing has to decide *where* the keyboard is, because it is only
/// ever in one place.
///
/// **→ and ← navigate, but only when the caret has nowhere left to go.** They
/// are the obvious keys for "into this" and "back out" — Finder's columns, every
/// file browser — but they are also how you move through what you have typed.
/// So the caret wins while it can still move: → expands only from the end of the
/// text, ← pops only from the start. With an empty field, which is the whole
/// time you are browsing, both are free. Tab stays bound to expand as well:
/// focus has nowhere to escape to, so the key was going spare.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focus: PaletteFocus
    /// -1 for up, +1 for down.
    var onMove: (Int) -> Void
    /// ⌘↑ / ⌘↓ — jump to the ends of the list.
    var onJump: (Int) -> Void
    var onSubmit: () -> Void
    /// → or ⇥ — expand the selected row into its own route.
    var onExpand: () -> Void
    /// ← — step back out of the current route.
    var onCollapse: () -> Void
    var onCancel: () -> Void
    /// ⌘1…⌘9 — jump straight to a pinned task.
    var onJumpTo: (Int) -> Bool = { _ in false }
    /// ⌘J — pin or unpin the selected row.
    var onToggleJump: () -> Bool = { false }
    /// ⌘↵ — add the selected row to the multi-open batch.
    var onToggleSelection: () -> Bool = { false }

    func makeNSView(context: Context) -> NSTextField {
        let field = PaletteTextField(string: text)
        field.onKeyEquivalent = { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return false }
            return coordinator.parent.handleKeyEquivalent(event)
        }
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        focus.field = field
        DispatchQueue.main.async { focus.take() }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only write back when they differ, or every keystroke fights the editor.
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    /// ⌘-chords the field editor never sees, because they are key *equivalents*
    /// rather than text commands.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let chars = event.charactersIgnoringModifiers else { return false }
        if let n = Int(chars), (1...9).contains(n) { return onJumpTo(n) }
        if chars.lowercased() == "j" { return onToggleJump() }
        // ⌘↵ arrives as a key equivalent, not as `insertNewline:`.
        if event.keyCode == UInt16(kVK_Return) || chars == "\r" { return onToggleSelection() }
        return false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        /// The caret sits after the last character, with nothing selected.
        private func atEnd(_ tv: NSTextView) -> Bool {
            let r = tv.selectedRange()
            return r.length == 0 && r.location >= (tv.string as NSString).length
        }

        /// The caret sits before the first character, with nothing selected.
        private func atStart(_ tv: NSTextView) -> Bool {
            let r = tv.selectedRange()
            return r.length == 0 && r.location == 0
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1); return true
            case #selector(NSResponder.moveToBeginningOfDocument(_:)),
                 #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                parent.onJump(-1); return true
            case #selector(NSResponder.moveToEndOfDocument(_:)),
                 #selector(NSResponder.scrollToEndOfDocument(_:)):
                parent.onJump(1); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveForward(_:)):
                // Only from the end of the text: while the caret can still move
                // right, moving it is what you meant.
                guard atEnd(textView) else { return false }
                parent.onExpand(); return true
            case #selector(NSResponder.moveLeft(_:)),
                 #selector(NSResponder.moveBackward(_:)):
                guard atStart(textView) else { return false }
                parent.onCollapse(); return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab can't mean "next field" — there is only one, and it must
                // never lose first responder. So it is a second way into a row.
                parent.onExpand(); return true
            case #selector(NSResponder.insertBacktab(_:)):
                return true   // nowhere for focus to go; keep it here
            default:
                return false
            }
        }
    }
}

/// The palette's field, which also answers ⌘-chords.
///
/// `performKeyEquivalent` is the only hook that sees them: a field editor turns
/// keystrokes into *text commands* (`moveUp:`, `insertNewline:`) and ⌘1 is not
/// one, so it never reaches `doCommandBy`. The window offers key equivalents to
/// the view tree first, which is where this sits.
final class PaletteTextField: NSTextField {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
