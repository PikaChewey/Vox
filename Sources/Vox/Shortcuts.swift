import AppKit
import Carbon.HIToolbox

/// A recorded key combination. Modifiers remember their side, so "left ⌘ left ⌥ V" doesn't fire on right ⌘.
/// `anySide` holds modifiers that may be pressed on either side (the built-in defaults use it).
struct Shortcut: Codable, Hashable {
    var keyCode: Int
    /// IOKit NX_DEVICE*KEYMASK bits: these exact keys must be down.
    var sided: UInt64 = 0
    /// Generic CGEventFlags bits (⌃⌥⇧⌘): either side counts.
    var anySide: UInt64 = 0

    struct Family { let generic: UInt64, left: UInt64, right: UInt64, symbol: String, name: String }
    /// In Apple's display order: ⌃ ⌥ ⇧ ⌘.
    static let families = [
        Family(generic: 0x40000, left: 0x01, right: 0x2000, symbol: "⌃", name: "Control"),
        Family(generic: 0x80000, left: 0x20, right: 0x40, symbol: "⌥", name: "Option"),
        Family(generic: 0x20000, left: 0x02, right: 0x04, symbol: "⇧", name: "Shift"),
        Family(generic: 0x100000, left: 0x08, right: 0x10, symbol: "⌘", name: "Command"),
    ]
    static let genericMask: UInt64 = 0x1E0000
    static let control: UInt64 = 0x40000, option: UInt64 = 0x80000, shift: UInt64 = 0x20000, command: UInt64 = 0x100000

    init(keyCode: Int, sided: UInt64 = 0, anySide: UInt64 = 0) {
        self.keyCode = keyCode; self.sided = sided; self.anySide = anySide
    }

    /// From a real key press: keeps the side of every modifier that was held.
    init(keyCode: Int, flags: UInt64) {
        self.keyCode = keyCode
        for f in Self.families where flags & f.generic != 0 {
            let side = flags & (f.left | f.right)
            if side == 0 { anySide |= f.generic } else { sided |= side }
        }
    }

    /// Generic bits the event must have: no more, no fewer.
    var requiredFamilies: UInt64 {
        Self.families.reduce(anySide & Self.genericMask) { acc, f in sided & (f.left | f.right) != 0 ? acc | f.generic : acc }
    }

    func matches(keyCode code: Int64, flags: UInt64) -> Bool {
        Int64(keyCode) == code && flags & Self.genericMask == requiredFamilies && flags & sided == sided
    }

    var hasCommandOptionOrControl: Bool { requiredFamilies & (Self.command | Self.option | Self.control) != 0 }

    /// Keycaps, e.g. ["left ⌘", "left ⌥", "V"].
    var keys: [String] {
        var out: [String] = []
        for f in Self.families {
            let l = sided & f.left != 0, r = sided & f.right != 0
            if anySide & f.generic != 0 || (l && r) { out.append(f.symbol) }
            else if l { out.append("left " + f.symbol) }
            else if r { out.append("right " + f.symbol) }
        }
        return out + [KeyNames.name(keyCode)]
    }

    var label: String { keys.joined(separator: " ") }

    /// Carbon modifiers for the fallback hot key (Carbon can't tell sides apart).
    var carbonModifiers: Int {
        let r = requiredFamilies
        return (r & Self.command != 0 ? cmdKey : 0) | (r & Self.shift != 0 ? shiftKey : 0)
            | (r & Self.option != 0 ? optionKey : 0) | (r & Self.control != 0 ? controlKey : 0)
    }

    /// For the menu's key-equivalent hint (the menu can't show sides).
    var menuEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        let name = KeyNames.name(keyCode)
        guard name.count == 1 else { return nil }
        // NSEvent.ModifierFlags uses the same bit values as CGEventFlags.
        return (name.lowercased(), NSEvent.ModifierFlags(rawValue: UInt(requiredFamilies)))
    }
}

/// Things you can bind a shortcut to (besides the dictation key itself).
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case pasteLast, pasteOriginal, cancel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteLast: return "Paste last dictation"
        case .pasteOriginal: return "Paste original of last"
        case .cancel: return "Cancel dictation"
        }
    }

    var detail: String {
        switch self {
        case .pasteLast: return "Pastes your last dictation again at the cursor."
        case .pasteOriginal: return "Pastes exactly what you said, without the AI edits."
        case .cancel: return "While recording or finishing. The key still reaches the app."
        }
    }

    /// The keystroke is kept from the app. Cancel isn't, so Esc still closes dialogs while you dictate.
    var swallows: Bool { self != .cancel }

    static let defaults: [ShortcutAction: Shortcut] = [
        .pasteLast: Shortcut(keyCode: kVK_ANSI_V, anySide: Shortcut.control | Shortcut.command),
        .cancel: Shortcut(keyCode: kVK_Escape),
    ]
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "Help",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let modifierKeyCodes: Set<Int> = [kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption, kVK_Control,
                                             kVK_RightControl, kVK_Shift, kVK_RightShift, kVK_Function, kVK_CapsLock]

    static func isFunctionKey(_ code: Int) -> Bool { special[code]?.hasPrefix("F") == true && special[code]!.count <= 3 }

    /// The key's name on the current keyboard layout ("V" on QWERTY, "." on Dvorak's V key).
    static func name(_ code: Int) -> String {
        if let s = special[code] { return s }
        if let c = character(code), !c.trimmingCharacters(in: .whitespaces).isEmpty { return c.uppercased() }
        return "key \(code)"
    }

    private static func character(_ code: Int) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: len)
    }
}
