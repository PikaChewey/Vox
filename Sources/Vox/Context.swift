import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What the user is typing into, captured at key-down (before our overlay or anything else can steal focus).
struct DictationContext {
    var app: NSRunningApplication?
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    /// Up to ~600 characters before the cursor in the focused field (local only; used so the cleanup can
    /// continue your sentence naturally and spell names already on screen).
    var textBeforeCursor: String?
    var category: AppCategory = .other

    static func capture(includeSelection: Bool) -> DictationContext {
        var c = DictationContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return c }
        c.app = app
        c.appName = app.localizedName
        c.bundleID = app.bundleIdentifier
        // Our own windows (onboarding practice box): AX calls into ourselves from the main thread would stall.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            c.category = .other
            return c
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        if let win: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) {
            c.windowTitle = attr(win, kAXTitleAttribute)
        }
        var focusedElement: AXUIElement? = attr(axApp, kAXFocusedUIElementAttribute)
        if focusedElement == nil {
            // Electron apps (VS Code, Cursor, Slack, Discord…) hide their tree until asked — but building it costs
            // them CPU, so ask only when needed and switch it back off later.
            AXBoost.enable(app.processIdentifier)
            focusedElement = attr(axApp, kAXFocusedUIElementAttribute)
        }
        if let focused = focusedElement {
            let subrole: String? = attr(focused, kAXSubroleAttribute)
            if subrole != kAXSecureTextFieldSubrole {
                if includeSelection, let sel: String = attr(focused, kAXSelectedTextAttribute), !sel.isEmpty {
                    c.selectedText = sel
                }
                if Settings.shared.useAppContext, let value: String = attr(focused, kAXValueAttribute), !value.isEmpty {
                    var cursor = value.utf16.count
                    var rangeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                       let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
                        var r = CFRange()
                        if AXValueGetValue(rv as! AXValue, .cfRange, &r) { cursor = min(max(0, r.location), value.utf16.count) }
                    }
                    let ns = value as NSString
                    let start = max(0, cursor - 600)
                    let before = ns.substring(with: NSRange(location: start, length: cursor - start))
                    c.textBeforeCursor = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
                }
            }
        }
        c.category = AppCategory.classify(bundleID: c.bundleID, appName: c.appName)
        if c.category == .other || isBrowser(c.bundleID), let t = c.windowTitle,
           let web = AppCategory.classifyBrowserTitle(t) {
            c.category = web
        }
        return c
    }

    static func isBrowser(_ id: String?) -> Bool {
        guard let id = id?.lowercased() else { return false }
        return ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion", "zen", "dia", "comet"].contains(where: id.contains)
    }

    /// Capitalized words already on screen (window title + text near the cursor): likely names to spell right.
    var visibleNames: [String] {
        let text = [windowTitle ?? "", textBeforeCursor ?? ""].joined(separator: " ")
        let words = text.split { !$0.isLetter && $0 != "'" }.map(String.init)
        var seen = Set<String>()
        return words.filter { w in
            guard w.count >= 3, let f = w.first, f.isUppercase, !Words.isReal(w) else { return false }
            return seen.insert(w).inserted
        }.prefix(12).map { $0 }
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}

/// Puts text at the cursor of the app you were dictating into: clipboard + ⌘V, then restores your clipboard.
enum TextInserter {
    enum Result { case pasted, copied(reason: String) }

    /// Pastes only if the app you started dictating in is still in front — never into whatever you switched to
    /// while it was transcribing. Otherwise the text is left on the clipboard so nothing is lost.
    @discardableResult
    static func insert(_ text: String, into target: NSRunningApplication?, pressReturn: Bool = false) -> Result {
        guard !text.isEmpty else { return .pasted }
        let pb = NSPasteboard.general
        let front = NSWorkspace.shared.frontmostApplication
        let sameApp = target == nil || front?.processIdentifier == target?.processIdentifier
        guard AXIsProcessTrusted(), sameApp else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .copied(reason: AXIsProcessTrusted() ? "You switched apps — press ⌘V" : "Copied — allow Accessibility to auto-paste")
        }
        let saved = Settings.shared.restoreClipboard ? snapshot(pb) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tell clipboard managers (Raycast, Maccy, Paste…) not to record this.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let changeCount = pb.changeCount

        press(keyFor("v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        if pressReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { press(CGKeyCode(kVK_Return), flags: []) }
        }

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Only restore if nothing else touched the clipboard in the meantime.
                guard pb.changeCount == changeCount else { return }
                pb.clearContents()
                pb.writeObjects(saved)
            }
        }
        return .pasted
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Fallback for apps whose AX tree doesn't expose the selection: copy it and read the clipboard.
    static func copySelectionViaClipboard() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        press(keyFor("c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != before { break }
        }
        let s = pb.changeCount != before ? pb.string(forType: .string) : nil
        pb.clearContents(); pb.writeObjects(saved)
        return s
    }

    /// The key code that types `char` in the current layout (so ⌘V works on Dvorak/AZERTY too).
    private static func keyFor(_ char: Character) -> CGKeyCode? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr, len == 1, let u = UnicodeScalar(chars[0]), Character(u) == char { return CGKeyCode(code) }
            }
            return nil
        }
    }
}

/// Spoken "press enter" at the very end sends the message (great for Claude Code / ChatGPT prompts).
enum AutoSend {
    private static let pattern = #"[\s,.;:!?-]*\b(?:press|hit)\s+(?:enter|return)[\s.!?]*$"#

    /// Returns the text without the trailing command, and whether to press Return.
    static func strip(_ text: String) -> (String, Bool) {
        guard Settings.shared.autoSend,
              let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return (text, false) }
        let rest = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest, !rest.isEmpty)
    }
}

/// Turns on Electron's accessibility tree only for apps we actually need to read, and turns it back off after
/// two quiet minutes (a full AX tree makes Chromium apps do extra work on every DOM change).
@MainActor
enum AXBoost {
    private static var enabled: [pid_t: DispatchWorkItem] = [:]

    nonisolated static func enable(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        DispatchQueue.main.async { MainActor.assumeIsolated { schedule(pid) } }
    }

    /// Keep it on while it's in use (e.g. the correction watcher reading the field).
    static func touch(_ pid: pid_t) { if enabled[pid] != nil { schedule(pid) } }

    private static func schedule(_ pid: pid_t) {
        enabled[pid]?.cancel()
        let w = DispatchWorkItem {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            MainActor.assumeIsolated { _ = enabled.removeValue(forKey: pid) }
        }
        enabled[pid] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
    }
}
