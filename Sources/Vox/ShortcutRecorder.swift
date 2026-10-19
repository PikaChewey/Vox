import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records one key binding at a time from the Settings window. While it listens, Vox's global keys are paused
/// so pressing the current shortcut (or the dictation key) records it instead of firing it.
@MainActor
final class KeyRecorder: ObservableObject {
    enum Target: Hashable { case trigger, action(ShortcutAction) }

    static let shared = KeyRecorder()

    @Published private(set) var target: Target?
    /// Why the last attempt was refused, shown under that row.
    @Published private(set) var problem: (target: Target, text: String)?

    private var monitor: Any?
    private var resignObserver: Any?
    /// Trigger recording: the lone modifier that is down, nil once a second key joins.
    private var pendingTrigger: TriggerKey?
    private var comboBroken = false

    func toggle(_ t: Target) { target == t ? stop() : start(t) }

    func start(_ t: Target) {
        stop()
        target = t
        problem = nil
        pendingTrigger = nil
        comboBroken = false
        HotkeyMonitor.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        monitor = nil; resignObserver = nil
        target = nil
        HotkeyMonitor.paused = false
    }

    private func refuse(_ text: String) {
        if let target { problem = (target, text) }
        NSSound.beep()
    }

    /// Returns true when the event was used (so it doesn't also reach the window).
    private func handle(_ e: NSEvent) -> Bool {
        guard let target else { return false }
        let flags = e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue)
        let code = Int(e.keyCode)
        switch target {
        case .trigger:
            if e.type == .keyDown {
                if code == kVK_Escape && flags & Shortcut.genericMask == 0 { stop(); return true }
                refuse("The dictation key is one key on its own: fn, or a left or right ⌘ ⌥ ⌃.")
                return true
            }
            if code == kVK_Shift || code == kVK_RightShift {
                if flags & Shortcut.shift != 0 {
                    refuse("⇧ is taken: hold it with the dictation key for Command mode.")
                    comboBroken = true; pendingTrigger = nil
                } else if flags & Shortcut.genericMask == 0 {
                    comboBroken = false
                }
                return true
            }
            guard let k = TriggerKey(keyCode: code) else { return true }
            if flags & k.downMask != 0 {
                // Down. Any other modifier still held makes this a combination, which isn't allowed.
                let others = flags & Shortcut.genericMask & ~k.family
                if pendingTrigger != nil || others != 0 { comboBroken = true; pendingTrigger = nil }
                else if !comboBroken { pendingTrigger = k }
            } else if pendingTrigger == k, !comboBroken {
                Settings.shared.trigger = k
                problem = nil
                stop()
            } else if flags & Shortcut.genericMask == 0 && flags & 0x800000 == 0 {
                if comboBroken { refuse("Press just one key: fn, or a left or right ⌘ ⌥ ⌃.") }
                comboBroken = false; pendingTrigger = nil
            }
            return true

        case .action(let action):
            guard e.type == .keyDown else { return true }
            let bare = flags & Shortcut.genericMask == 0
            if bare && code == kVK_Escape && action != .cancel { stop(); return true }
            if bare && (code == kVK_Delete || code == kVK_ForwardDelete) {
                Settings.shared.shortcuts[action] = nil
                problem = nil
                stop(); return true
            }
            let sc = Shortcut(keyCode: code, flags: flags)
            if let why = Self.problem(with: sc, for: action, among: Settings.shared.shortcuts) { refuse(why); return true }
            Settings.shared.shortcuts[action] = sc
            problem = nil
            stop()
            return true
        }
    }

    /// Why `sc` can't be used for `action`, or nil if it's fine.
    static func problem(with sc: Shortcut, for action: ShortcutAction, among all: [ShortcutAction: Shortcut]) -> String? {
        let name = KeyNames.name(sc.keyCode)
        let fKey = KeyNames.isFunctionKey(sc.keyCode)
        let special = name.count > 1 || "↩⇥⌫⌦←→↓↑⌤".contains(name)
        if action.swallows {
            if !sc.hasCommandOptionOrControl && !fKey {
                return "Add ⌘, ⌥ or ⌃, or it would block normal typing of \(name)."
            }
        } else if !sc.hasCommandOptionOrControl && !special {
            return "Add ⌘, ⌥ or ⌃, or typing \(name) would cancel your dictation."
        }
        if sc.requiredFamilies == Shortcut.command,
           [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_S, kVK_Tab, kVK_Space]
            .contains(sc.keyCode) {
            return "⌘\(name) is used by every app. Add another key, like ⌥ or ⌃."
        }
        for (other, existing) in all where other != action {
            if overlaps(existing, sc) { return "Already used for \(other.title.lowercased())." }
        }
        return nil
    }

    /// Two shortcuts overlap when one key press could match both.
    static func overlaps(_ a: Shortcut, _ b: Shortcut) -> Bool {
        guard a.keyCode == b.keyCode, a.requiredFamilies == b.requiredFamilies else { return false }
        for f in Shortcut.families {
            let sa = a.sided & (f.left | f.right), sb = b.sided & (f.left | f.right)
            // Left-only vs right-only can't both match one press; anything else can.
            if sa != 0, sb != 0, sa & sb == 0, sa != (f.left | f.right), sb != (f.left | f.right) { return false }
        }
        return true
    }
}

/// The capsule you click to record: shows the keycaps, or "Press keys…" while listening.
struct KeyField: View {
    let target: KeyRecorder.Target
    let keys: [String]?
    var placeholder = "Not set"
    @ObservedObject private var recorder = KeyRecorder.shared

    var body: some View {
        let on = recorder.target == target
        Button { recorder.toggle(target) } label: {
            HStack(spacing: 6) {
                if on {
                    Text(target == .trigger ? "Press one key…" : "Press keys…")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink)
                } else if let keys {
                    KeyCombo(keys: keys)
                } else {
                    Text(placeholder).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                }
            }
            .frame(minWidth: 120, minHeight: 24)
            .padding(.horizontal, 8)
            .background(Capsule().fill(on ? Color.wash : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.ink : Color.ink4, lineWidth: on ? 1.3 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Press the keys now. Click again to stop." : "Click, then press the keys you want.")
        .accessibilityLabel(on ? "Recording. Press the keys now." : (keys?.joined(separator: " ") ?? placeholder))
        .onDisappear { if recorder.target == target { recorder.stop() } }
    }
}
