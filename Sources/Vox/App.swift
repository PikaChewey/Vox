import AppKit
import Combine
import SwiftUI

@main
struct VoxMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            SelfTest.run(path: args[i + 1], app: args.dropFirst(i + 2).first)
            return
        }
        if args.contains("--test-text") { SelfTest.text(); return }
        if let i = args.firstIndex(of: "--asr-bench"), i + 1 < args.count {
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await ASRBench.run(path: args[i + 1]); sem.signal() }
            sem.wait()
            return
        }
        if let i = args.firstIndex(of: "--mic-test"), i + 2 < args.count {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in await StreamTest.mic(path: args[i + 1], out: args[i + 2]); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let i = args.firstIndex(of: "--stream-test"), i + 1 < args.count {
            let app = args.count > i + 2 ? args[i + 2] : nil
            let speed = args.count > i + 3 ? Double(args[i + 3]) ?? 1 : 1
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in await StreamTest.run(path: args[i + 1], app: app, speed: speed); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { RenderUI.run(args[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let nav = Navigator()
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var stateWatch: AnyCancellable?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.icon("waveform")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.start()
        if !Settings.shared.onboarded {
            showOnboarding()
        } else if !controller.hotkeysActive {
            openMain(.settings)
        }

        NotificationCenter.default.addObserver(forName: .voxOpenSection, object: nil, queue: .main) { [weak self] n in
            let s = (n.object as? String).flatMap(Section.init(rawValue:)) ?? .home
            Task { @MainActor in self?.openMain(s) }
        }
        NotificationCenter.default.addObserver(forName: .voxShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showOnboarding() }
        }

        // Menu-bar icon: changes only when the state changes (no animation, no timer — zero idle wakeups).
        stateWatch = controller.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateIcon(state: state) }
        // Until the hotkey works (permissions pending), re-check every 2 s; then stop polling.
        if !controller.hotkeysActive {
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    if !self.controller.hotkeysActive, HotkeyMonitor.accessibilityTrusted { self.controller.startHotkeys() }
                    if self.controller.hotkeysActive { t.invalidate(); self.permissionPoll = nil }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioDevices.unduck()
        let llama = controller.llama
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await llama.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 1)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain(.home)
        return true
    }

    private static func icon(_ name: String, value: Double? = nil) -> NSImage? {
        let img = value.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: "Vox") }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: "Vox")
        img?.isTemplate = true
        return img
    }

    private func updateIcon(state: DictationController.State) {
        let name: String
        switch state {
        case .idle: name = "waveform"
        case .recording: name = "waveform.circle.fill"
        case .processing: name = "ellipsis.circle"
        }
        statusItem.button?.image = Self.icon(name)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let h = History.shared
        let s = Settings.shared
        menu.addItem(header(controller.speechReady ? "Vox is ready" : controller.statusLine,
                            sub: "\(h.totalWords.formatted()) words · \(h.wordsToday.formatted()) today · \(h.streakDays)-day streak"))
        menu.addItem(.separator())
        menu.addItem(disabled(s.holdToTalk
            ? "Hold \(s.trigger.label) to talk  ·  double-tap for hands-free  ·  + ⇧ command"
            : "Tap \(s.trigger.label) to talk, tap again to finish  ·  + ⇧ command"))
        menu.addItem(.separator())

        let open = item("Open Vox", #selector(openHome), key: "o")
        menu.addItem(open)
        let paste = item("Paste Last Dictation", #selector(pasteLast))
        paste.keyEquivalent = "v"; paste.keyEquivalentModifierMask = [.control, .command]
        paste.isEnabled = controller.lastText != nil || !h.entries.isEmpty
        menu.addItem(paste)
        let orig = item("Paste Original of Last (no AI edits)", #selector(pasteOriginal))
        orig.isEnabled = controller.lastRaw != nil || !h.entries.isEmpty
        menu.addItem(orig)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Vox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String, sub: String) -> NSMenuItem {
        let i = NSMenuItem()
        let v = NSHostingView(rootView: VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.horizontal, 14).padding(.vertical, 6).frame(width: 300, alignment: .leading))
        v.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        i.view = v
        return i
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openHome() { openMain(.home) }
    @objc private func openSettings() { openMain(.settings) }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func pasteOriginal() { controller.pasteLastOriginal() }

    // MARK: Windows

    func openMain(_ section: Section) {
        nav.section = section
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Vox"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.contentViewController = NSHostingController(rootView: MainWindow(controller: controller, nav: nav))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("VoxMain")
            if !w.setFrameUsingName("VoxMain") { w.center() }
            w.delegate = self
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)   // show in Dock + ⌘Tab while the window is open
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: OnboardingView(controller: controller, finish: { [weak self] in
                Settings.shared.onboarded = true
                self?.onboardingWindow?.close()
            }))
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let w = notification.object as? NSWindow
        if w === onboardingWindow { onboardingWindow = nil }
        // Free the whole SwiftUI tree (and its History/Settings subscriptions) when the window closes.
        if w === mainWindow { mainWindow = nil }
        // Back to a pure menu-bar app once no windows are open.
        DispatchQueue.main.async {
            if NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) }).isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
