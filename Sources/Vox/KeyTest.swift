import AppKit
import Carbon.HIToolbox

/// `Vox --test-keys`: checks that shortcuts and the dictation key do what they say.
/// Part 1 feeds made-up events to the monitor's decision logic. Part 2 runs the real event tap: it posts
/// ⌃⌥⌘F19 (bound to nothing anywhere) and checks the action fires and the keystroke never gets past Vox.
enum KeyTest {
    private static var failures = 0

    private static func check(_ label: String, _ ok: Bool, _ got: Any = "") {
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 52, withPad: " ", startingAt: 0)) \(ok ? "" : "got \(got)")")
    }

    // Generic + side (device) bits.
    static let lCmd: UInt64 = Shortcut.command | 0x08, rCmd: UInt64 = Shortcut.command | 0x10
    static let lOpt: UInt64 = Shortcut.option | 0x20, rOpt: UInt64 = Shortcut.option | 0x40
    static let lCtrl: UInt64 = Shortcut.control | 0x01, lShift: UInt64 = Shortcut.shift | 0x02

    static func run() -> Bool {
        MainActor.assumeIsolated { logic(); recorderRules() }
        live()
        print(failures == 0 ? "all key tests passed" : "\(failures) key test(s) FAILED")
        return failures == 0
    }

    private static func monitor(trigger: TriggerKey, _ shortcuts: [ShortcutAction: Shortcut]) -> HotkeyMonitor {
        let m = HotkeyMonitor()
        m.trigger = { trigger }
        m.shortcuts = { shortcuts }
        m.filtering = true
        return m
    }

    /// Runs one event through the monitor: (swallowed?, events emitted).
    private static func feed(_ m: HotkeyMonitor, _ type: CGEventType, _ code: Int, _ flags: UInt64,
                             repeat r: Bool = false) -> (Bool, [HotkeyMonitor.Event]) {
        var out: [HotkeyMonitor.Event] = []
        let s = m.process(type: type, code: Int64(code), flags: flags, autorepeat: r) { out.append($0) }
        return (s, out)
    }

    @MainActor private static func logic() {
        print("— shortcuts")
        let mine = Shortcut(keyCode: kVK_ANSI_V, flags: lCmd | lOpt)
        check("recorded left ⌘ left ⌥ V keeps sides", mine.sided == 0x28 && mine.anySide == 0, mine)
        check("its keycaps", mine.keys == ["left ⌥", "left ⌘", "V"], mine.keys)
        let data = try! JSONEncoder().encode([ShortcutAction.pasteLast: mine])
        check("saves and loads", (try? JSONDecoder().decode([ShortcutAction: Shortcut].self, from: data))?[.pasteLast] == mine)

        var m = monitor(trigger: .rightCommand, [.pasteLast: mine, .cancel: ShortcutAction.defaults[.cancel]!])
        var r = feed(m, .keyDown, kVK_ANSI_V, lCmd | lOpt)
        check("left ⌘ left ⌥ V → paste last, kept from app", r.0 && r.1 == [.shortcut(.pasteLast)], r)
        r = feed(m, .keyDown, kVK_ANSI_V, lCmd | lOpt, repeat: true)
        check("…key repeat is swallowed but fires once", r.0 && r.1.isEmpty, r)
        r = feed(m, .keyUp, kVK_ANSI_V, lCmd | lOpt)
        check("…its key-up is swallowed too", r.0 && r.1.isEmpty, r)
        r = feed(m, .keyUp, kVK_ANSI_V, 0)
        check("a later plain V key-up passes", !r.0, r)
        r = feed(m, .keyDown, kVK_ANSI_V, rCmd | rOpt)
        check("right ⌘ right ⌥ V doesn't fire, reaches app", !r.0 && r.1.isEmpty, r)
        r = feed(m, .keyDown, kVK_ANSI_V, lCmd | rOpt)
        check("left ⌘ right ⌥ V doesn't fire", !r.0 && r.1.isEmpty, r)
        r = feed(m, .keyDown, kVK_ANSI_V, lCmd | lOpt | lShift)
        check("left ⌘ left ⌥ ⇧ V doesn't fire (extra key)", !r.0 && r.1.isEmpty, r)
        r = feed(m, .keyDown, kVK_ANSI_V, lCmd)
        check("plain ⌘V (normal paste) reaches app", !r.0 && r.1.isEmpty, r)
        r = feed(m, .keyDown, kVK_ANSI_C, lCmd | lOpt)
        check("left ⌘ left ⌥ C doesn't fire", !r.0 && r.1.isEmpty, r)
        r = feed(m, .keyDown, kVK_Escape, 0)
        check("esc → cancel, still reaches app", !r.0 && r.1 == [.shortcut(.cancel)], r)

        m = monitor(trigger: .rightCommand, ShortcutAction.defaults)
        r = feed(m, .keyDown, kVK_ANSI_V, lCtrl | rCmd)
        check("default ⌃⌘V works with either side", r.0 && r.1 == [.shortcut(.pasteLast)], r)
        r = feed(m, .keyDown, kVK_ANSI_V, lCtrl | lCmd)
        check("…left ⌘ too", r.0 && r.1 == [.shortcut(.pasteLast)], r)

        m = monitor(trigger: .rightCommand, ShortcutAction.defaults)
        m.filtering = false
        r = feed(m, .keyDown, kVK_ANSI_V, lCtrl | lCmd)
        check("without Accessibility, Carbon handles it", !r.0 && r.1.isEmpty, r)

        print("— dictation key")
        m = monitor(trigger: .rightCommand, [.pasteLast: mine])
        r = feed(m, .flagsChanged, kVK_Command, lCmd)
        check("left ⌘ is not the right ⌘ key", r.1.isEmpty, r)
        _ = feed(m, .flagsChanged, kVK_Command, 0)
        r = feed(m, .flagsChanged, kVK_RightCommand, rCmd)
        check("right ⌘ down → start", r.1 == [.triggerDown(shift: false)], r)
        r = feed(m, .flagsChanged, kVK_Shift, rCmd | lShift)
        check("+ ⇧ → command mode", r.1 == [.shiftWhileHeld], r)
        r = feed(m, .flagsChanged, kVK_RightCommand, lShift)
        check("right ⌘ up → stop", r.1 == [.triggerUp], r)
        _ = feed(m, .flagsChanged, kVK_Shift, 0)
        _ = feed(m, .flagsChanged, kVK_RightCommand, rCmd)
        r = feed(m, .keyDown, kVK_ANSI_C, rCmd)
        check("right ⌘ C is a shortcut → cancel, C reaches app", !r.0 && r.1 == [.otherKeyWhileHeld], r)
        r = feed(m, .leftMouseDown, 0, rCmd)
        check("right ⌘-click → cancel", r.1 == [.otherKeyWhileHeld], r)
        r = feed(m, .flagsChanged, kVK_Option, rCmd | lOpt)
        check("right ⌘ + ⌥ → cancel", r.1 == [.otherKeyWhileHeld], r)
        _ = feed(m, .flagsChanged, kVK_Option, rCmd)
        _ = feed(m, .flagsChanged, kVK_RightCommand, 0)

        m = monitor(trigger: .leftCommand, [:])
        r = feed(m, .flagsChanged, kVK_RightCommand, rCmd)
        check("recorded left ⌘: right ⌘ ignored", r.1.isEmpty, r)
        _ = feed(m, .flagsChanged, kVK_RightCommand, 0)
        r = feed(m, .flagsChanged, kVK_Command, lCmd | Shortcut.shift | 0x02)
        check("recorded left ⌘: left ⌘ (with ⇧) → command start", r.1 == [.triggerDown(shift: true)], r)
        _ = feed(m, .flagsChanged, kVK_Command, 0)

        m = monitor(trigger: .fn, [:])
        r = feed(m, .flagsChanged, kVK_Function, 0x800000)
        check("fn down → start", r.1 == [.triggerDown(shift: false)], r)
        r = feed(m, .flagsChanged, kVK_Command, 0x800000 | lCmd)
        check("fn + ⌘ → cancel", r.1 == [.otherKeyWhileHeld], r)
        _ = feed(m, .flagsChanged, kVK_Command, 0x800000)
        r = feed(m, .flagsChanged, kVK_Function, 0)
        check("fn up → stop", r.1 == [.triggerUp], r)

        m = monitor(trigger: .rightCommand, [.pasteLast: mine])
        HotkeyMonitor.paused = true
        let p1 = feed(m, .keyDown, kVK_ANSI_V, lCmd | lOpt), p2 = feed(m, .flagsChanged, kVK_RightCommand, rCmd)
        HotkeyMonitor.paused = false
        check("while recording a shortcut nothing fires", !p1.0 && p1.1.isEmpty && p2.1.isEmpty, (p1, p2))
    }

    @MainActor private static func recorderRules() {
        print("— recorder rules")
        let all = ShortcutAction.defaults
        func why(_ code: Int, _ flags: UInt64, _ a: ShortcutAction, _ among: [ShortcutAction: Shortcut] = all) -> String? {
            KeyRecorder.problem(with: Shortcut(keyCode: code, flags: flags), for: a, among: among)
        }
        check("left ⌘ left ⌥ V accepted for paste last", why(kVK_ANSI_V, lCmd | lOpt, .pasteLast) == nil, why(kVK_ANSI_V, lCmd | lOpt, .pasteLast) ?? "")
        check("plain V refused", why(kVK_ANSI_V, 0, .pasteLast) != nil)
        check("⇧V refused", why(kVK_ANSI_V, lShift, .pasteLast) != nil)
        check("⌘V refused (every app's paste)", why(kVK_ANSI_V, lCmd, .pasteOriginal) != nil)
        check("F19 alone accepted", why(kVK_F19, 0, .pasteOriginal) == nil)
        check("⌃⌘V for paste original refused (taken)", why(kVK_ANSI_V, lCtrl | rCmd, .pasteOriginal) != nil)
        let sided: [ShortcutAction: Shortcut] = [.pasteLast: Shortcut(keyCode: kVK_ANSI_V, flags: lCmd | lOpt)]
        check("right ⌘ right ⌥ V free when paste last is left-sided", why(kVK_ANSI_V, rCmd | rOpt, .pasteOriginal, sided) == nil)
        check("esc accepted for cancel", why(kVK_Escape, 0, .cancel) == nil)
        check("plain X refused for cancel", why(kVK_ANSI_X, 0, .cancel) != nil)
    }

    /// The real tap, end to end. Uses ⌃⌥⌘F19, which nothing else uses, so a failure can't do anything.
    private static func live() {
        print("— live event tap")
        guard AXIsProcessTrusted() else { check("Accessibility granted to this binary", false, "not trusted"); return }
        let combo = Shortcut(keyCode: kVK_F19, flags: lCtrl | lOpt | lCmd)
        let m = HotkeyMonitor()
        m.trigger = { .rightControl }
        m.shortcuts = { [.pasteOriginal: combo] }
        m.ignoreOwnEvents = false
        var fired: [HotkeyMonitor.Event] = []
        m.handler = { fired.append($0) }
        check("filtering tap starts", m.start(), "listen-only")

        // A second, listen-only tap behind Vox's: it only sees what Vox let through.
        var behind: [UInt64] = []
        let box = Unmanaged.passRetained(Box { behind.append($0) })
        let ctx = box.toOpaque()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let spy = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, e, ctx in
            if type == .keyDown || type == .keyUp,
               e.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_F19) {
                Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue().f(e.flags.rawValue)
            }
            return Unmanaged.passUnretained(e)
        }, userInfo: ctx) else { check("spy tap", false); return }
        let src = CFMachPortCreateRunLoopSource(nil, spy, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        func post(_ flags: UInt64) {
            // A private source: posting never changes the modifier keys the user is really holding.
            let s = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: s, virtualKey: CGKeyCode(kVK_F19), keyDown: down)
                e?.flags = CGEventFlags(rawValue: flags)
                e?.post(tap: .cghidEventTap)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        post(lCtrl | lOpt | lCmd)
        check("left ⌃⌥⌘ F19 fires the action", fired == [.shortcut(.pasteOriginal)], fired)
        check("…and no app sees the keystroke", behind.isEmpty, "\(behind.count) events got through")

        fired = []; behind = []
        post(Shortcut.control | 0x2000 | rOpt | rCmd)
        check("right ⌃⌥⌘ F19 doesn't fire", fired.isEmpty, fired)
        check("…and reaches apps normally", behind.count == 2, "\(behind.count) events")

        fired = []; behind = []
        m.ignoreOwnEvents = true
        post(lCtrl | lOpt | lCmd)
        check("Vox's own synthetic keys never fire shortcuts", fired.isEmpty, fired)

        m.stop()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: spy, enable: false)
        box.release()
    }

    private final class Box { let f: (UInt64) -> Void; init(_ f: @escaping (UInt64) -> Void) { self.f = f } }
}

