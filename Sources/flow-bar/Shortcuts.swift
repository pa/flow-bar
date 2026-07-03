import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut: a key code + Carbon modifier mask, plus a
/// human-readable label (e.g. "⌥⌘F"). Persisted in UserDefaults.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let key = "toggleShortcut"
    /// Default: ⌥⌘F.
    static let defaultShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(cmdKey | optionKey),
        display: "⌥⌘F")

    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return defaultShortcut }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Registers a single global hotkey via Carbon `RegisterEventHotKey` — works
/// system-wide with NO Accessibility permission (unlike NSEvent monitors), and
/// fires even when flow-bar isn't frontmost.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    private init() {}

    func register(_ s: Shortcut) {
        installHandlerIfNeeded()
        unregister()
        guard s.carbonModifiers != 0 else { return }
        let id = EventHotKeyID(signature: 0x464C_4257 /* 'FLBW' */, id: 1)
        RegisterEventHotKey(s.keyCode, s.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            if let userData {
                let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onFire?() }
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
    }
}

// MARK: - Recorder

/// Build a display string ("⌃⌥⇧⌘F") from NSEvent modifier flags + key.
private func shortcutDisplay(_ mods: NSEvent.ModifierFlags, key: String) -> String {
    var s = ""
    if mods.contains(.control) { s += "⌃" }
    if mods.contains(.option)  { s += "⌥" }
    if mods.contains(.shift)   { s += "⇧" }
    if mods.contains(.command) { s += "⌘" }
    return s + key
}

/// SwiftUI control: shows the current shortcut; click to record a new one.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.shortcut = shortcut
        v.onRecord = { self.shortcut = $0 }
        return v
    }
    func updateNSView(_ v: RecorderView, context: Context) { v.shortcut = shortcut }

    /// A small button-like NSView that captures the next key combo when active.
    final class RecorderView: NSButton {
        var onRecord: ((Shortcut) -> Void)?
        var shortcut: Shortcut = .load() { didSet { if !recording { title = shortcut.display } } }
        private var recording = false { didSet { title = recording ? "Type shortcut…" : shortcut.display } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            title = shortcut.display
            target = self
            action = #selector(begin)
            font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func begin() { recording = true; window?.makeFirstResponder(self) }
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt32(kVK_Escape) { recording = false; return }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if mods.contains(.command) { carbon |= UInt32(cmdKey) }
            if mods.contains(.option)  { carbon |= UInt32(optionKey) }
            if mods.contains(.control) { carbon |= UInt32(controlKey) }
            if mods.contains(.shift)   { carbon |= UInt32(shiftKey) }
            guard carbon != 0 else { NSSound.beep(); return }   // require a modifier
            let key = (event.charactersIgnoringModifiers ?? "").uppercased()
            let s = Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                             display: shortcutDisplay(mods, key: key))
            shortcut = s
            recording = false
            onRecord?(s)
        }
    }
}
