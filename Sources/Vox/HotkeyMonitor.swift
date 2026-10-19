import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global keys via one CGEventTap: the dictation key (a lone modifier: fn, or left/right ⌥ ⌘ ⌃), shift for
/// Command mode, and your recorded shortcuts. The tap filters (with Accessibility) so a matched shortcut
/// never reaches the app; without Accessibility it only listens and Carbon hot keys stand in for shortcuts.
final class HotkeyMonitor {
    enum Event: Equatable {
        case triggerDown(shift: Bool)
        case triggerUp
        case shiftWhileHeld
        case otherKeyWhileHeld      // e.g. fn+← or fn+⌘ or a ⌘-click: the user is doing a shortcut, not dictating
        case shortcut(ShortcutAction)
    }

    var handler: ((Event) -> Void)?
    /// While Settings records a shortcut every key passes straight through and nothing fires.
    static var paused = false
    var trigger: () -> TriggerKey = { Settings.shared.trigger }
    var shortcuts: () -> [ShortcutAction: Shortcut] = { Settings.shared.shortcuts }
    /// Vox's own synthetic ⌘V must never trigger (or be eaten by) a shortcut. The self-test turns this off.
    var ignoreOwnEvents = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Set by start(); the self-test sets it to check the filtering decisions without a tap.
    var filtering = false
    private var triggerHeld = false
    /// Key-ups of swallowed shortcuts, so the app never sees half a keystroke.
    private var swallowedUps: Set<Int64> = []
    private var fallbackKeys: [GlobalHotKey] = []

    private static let kLShift: Int64 = 56, kRShift: Int64 = 60
    private static let otherModifiers: UInt64 = Shortcut.command | Shortcut.option | Shortcut.control

    /// True once the filtering tap runs (listen-only means Accessibility is still missing).
    var isRunning: Bool { tap != nil && filtering }

    @discardableResult
    func start() -> Bool {
        stop()
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, ctx in
            let m = Unmanaged<HotkeyMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            return m.tapped(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        for options in [CGEventTapOptions.defaultTap, .listenOnly] {
            if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                         eventsOfInterest: mask, callback: callback, userInfo: me) {
                tap = t
                filtering = options == .defaultTap
                break
            }
        }
        guard let t = tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        refreshFallback()
        NSLog("Vox: hotkeys \(filtering ? "filtering" : "listen-only, shortcuts via Carbon (no Accessibility)")")
        return filtering
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; triggerHeld = false; filtering = false
        swallowedUps.removeAll()
        fallbackKeys.removeAll()
    }

    /// Carbon hot keys for the shortcuts when the tap can't filter. Call again after shortcuts change.
    func refreshFallback() {
        fallbackKeys.removeAll()
        guard tap != nil, !filtering else { return }
        for (i, (action, sc)) in shortcuts().sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() where action.swallows {
            fallbackKeys.append(GlobalHotKey(keyCode: sc.keyCode, modifiers: sc.carbonModifiers, id: UInt32(10 + i)) { [weak self] in
                guard !HotkeyMonitor.paused else { return }
                self?.handler?(.shortcut(action))
            })
        }
    }

    /// Runs inside the tap, which holds up the user's typing, so it only decides and defers the work.
    private func tapped(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        if ignoreOwnEvents, event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
        var events: [Event] = []
        let swallow = process(type: type, code: event.getIntegerValueField(.keyboardEventKeycode),
                              flags: event.flags.rawValue,
                              autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) { events.append($0) }
        if !events.isEmpty {
            DispatchQueue.main.async { [weak self] in for e in events { self?.handler?(e) } }
        }
        return swallow
    }

    /// What one event means. Returns true to keep it from the app. Only touches the held-key state, so the
    /// self-test can drive it with made-up events.
    func process(type: CGEventType, code: Int64, flags: UInt64, autorepeat: Bool, emit: (Event) -> Void) -> Bool {
        if Self.paused { triggerHeld = false; return false }
        switch type {
        case .keyDown:
            if let (action, _) = shortcuts().first(where: { $0.value.matches(keyCode: code, flags: flags) }) {
                if action.swallows && !filtering { return false }      // the Carbon fallback handles it
                if !autorepeat {
                    if triggerHeld && action != .cancel { emit(.otherKeyWhileHeld) }
                    emit(.shortcut(action))
                }
                guard action.swallows else { return false }
                swallowedUps.insert(code)
                return true
            }
            if triggerHeld { emit(.otherKeyWhileHeld) }
            return false
        case .keyUp:
            return swallowedUps.remove(code) != nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if triggerHeld { emit(.otherKeyWhileHeld) }
            return false
        case .flagsChanged:
            let t = trigger()
            if code == Int64(t.keyCode) {
                let down = flags & t.downMask != 0
                if down && !triggerHeld {
                    triggerHeld = true
                    emit(.triggerDown(shift: flags & Shortcut.shift != 0))
                } else if !down && triggerHeld {
                    triggerHeld = false
                    emit(.triggerUp)
                }
                return false
            }
            guard triggerHeld else { return false }
            if code == Self.kLShift || code == Self.kRShift {
                if flags & Shortcut.shift != 0 { emit(.shiftWhileHeld) }
            } else if flags & Self.otherModifiers & ~t.family != 0 {
                // Another modifier joined the dictation key: it's a shortcut (fn+⌘…), not dictation.
                emit(.otherKeyWhileHeld)
            }
            return false
        default:
            return false
        }
    }

    // MARK: Permissions

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static func promptInputMonitoring() { _ = CGRequestListenEventAccess() }
}

/// Classic Carbon hot key (consumes the keystroke). Only a fallback: it can't tell left ⌘ from right ⌘.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        Self.handlers[id] = action
        if !Self.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let h = GlobalHotKey.handlers[hk.id]
                DispatchQueue.main.async { h?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.installed = true
        }
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x564F5820) /* "VOX " */, id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }
}
