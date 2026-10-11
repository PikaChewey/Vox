import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global push-to-talk via a listen-only CGEventTap. Watches modifier changes (fn, right ⌥/⌘/⌃, shift, control)
/// plus key-downs (for Esc and to notice when the trigger is being used as part of a normal shortcut).
final class HotkeyMonitor {
    enum Event {
        case triggerDown(shift: Bool)
        case triggerUp
        case shiftWhileHeld
        case otherKeyWhileHeld      // e.g. fn+← or fn+⌘: the user is doing a shortcut, not dictating
        case escape
        case keyDown
    }

    var handler: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerHeld = false

    private static let kFn: Int64 = 63, kROpt: Int64 = 61, kRCmd: Int64 = 54, kRCtrl: Int64 = 62
    private static let kLShift: Int64 = 56, kRShift: Int64 = 60, kLCtrl: Int64 = 59, kLOpt: Int64 = 58, kEsc: Int64 = 53

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) distinguish left from right.
    private static let devROpt: UInt64 = 0x40, devRCmd: UInt64 = 0x10, devRCtrl: UInt64 = 0x2000

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, ctx in
                                            let m = Unmanaged<HotkeyMonitor>.fromOpaque(ctx!).takeUnretainedValue()
                                            m.handle(type: type, event: event)
                                            return Unmanaged.passUnretained(event)
                                        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; triggerHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let raw = flags.rawValue

        if type == .keyDown {
            if code == Self.kEsc { emit(.escape); return }
            emit(triggerHeld ? .otherKeyWhileHeld : .keyDown)
            return
        }
        guard type == .flagsChanged else { return }

        let trigger = Settings.shared.trigger
        let isTriggerKey: Bool
        let down: Bool
        switch trigger {
        case .fn: isTriggerKey = code == Self.kFn; down = flags.contains(.maskSecondaryFn)
        case .rightOption: isTriggerKey = code == Self.kROpt; down = raw & Self.devROpt != 0
        case .rightCommand: isTriggerKey = code == Self.kRCmd; down = raw & Self.devRCmd != 0
        case .rightControl: isTriggerKey = code == Self.kRCtrl; down = raw & Self.devRCtrl != 0
        }
        if isTriggerKey {
            if down && !triggerHeld {
                triggerHeld = true
                emit(.triggerDown(shift: flags.contains(.maskShift)))
            } else if !down && triggerHeld {
                triggerHeld = false
                emit(.triggerUp)
            }
            return
        }
        guard triggerHeld else { return }
        if code == Self.kLShift || code == Self.kRShift {
            if flags.contains(.maskShift) { emit(.shiftWhileHeld) }
        } else if !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty, trigger == .fn {
            // Another modifier joined fn: it's a shortcut (fn+⌘…), not dictation.
            emit(.otherKeyWhileHeld)
        }
    }

    private func emit(_ e: Event) { handler?(e) }

    // MARK: Permissions

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static func promptInputMonitoring() { _ = CGRequestListenEventAccess() }
}

/// Classic Carbon hot key (consumes the keystroke) — used for ⌃⌘V "paste last dictation".
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
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x534F5454), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }
}
