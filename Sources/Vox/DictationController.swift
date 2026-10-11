import AppKit
import AVFoundation
import Foundation

/// The whole pipeline: hotkey → mic → Parakeet → cleanup → paste at cursor.
///
/// Controls (default trigger: fn):
///   • Hold fn, talk, release            → dictate
///   • Double-tap fn                     → hands-free; tap fn again to finish
///   • Hold fn + ⇧                       → Command mode: rewrite the selection, or write something new
///   • Esc while recording               → cancel
///   • ⌃⌘V                               → paste your last dictation again
@MainActor
final class DictationController: ObservableObject {
    enum Mode: String { case dictate, command }
    enum State: Equatable { case idle, recording, processing }

    @Published private(set) var state: State = .idle
    @Published private(set) var mode: Mode = .dictate
    @Published var statusLine = "Starting…"
    @Published var speechReady = false
    @Published var lastText: String?
    @Published var lastRaw: String?

    let overlay = OverlayController()
    let transcriber = Transcriber()
    let llama = LlamaServer()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private let watcher = CorrectionWatcher()
    private var pasteLastKey: GlobalHotKey?

    private var locked = false
    private var pressTime = Date()
    private var lastShortTap: Date?
    private var pendingTapDiscard: DispatchWorkItem?
    private var context = DictationContext()
    private var live: LiveDictation?
    private var cleaner: IncrementalCleaner?
    /// Chime, ducking, the island and model warm-up wait ~0.18 s, so fn+arrow / fn+delete shortcuts never flash
    /// the UI or wake the models. The mic itself starts instantly so no syllable is lost.
    private var armWork: DispatchWorkItem?
    private var processingTask: Task<Void, Never>?

    private let tapThreshold = 0.25
    private let doubleTapWindow = 0.40

    func start() {
        AudioDevices.unduck()   // in case a previous run crashed mid-dictation
        hotkeys.handler = { [weak self] e in self?.handle(e) }
        startHotkeys()
        pasteLastKey = GlobalHotKey(keyCode: 9 /* V */, modifiers: 0x1000 | 0x0100 /* ⌃⌘ */, id: 1) { [weak self] in
            self?.pasteLast()
        }
        Task { await self.loadModels() }
    }

    func startHotkeys() {
        if !hotkeys.start() { statusLine = "Needs Accessibility + Input Monitoring permission" }
    }

    var hotkeysActive: Bool { hotkeys.isRunning }

    func loadModels() async {
        statusLine = "Loading speech model…"
        do {
            try await transcriber.load { s in Task { @MainActor in self.statusLine = "Speech model: \(s)" } }
            await transcriber.configureVocabulary(Settings.shared.dictionary)
            speechReady = true
            statusLine = "Ready"
        } catch {
            statusLine = "Speech model failed: \(error.localizedDescription)"
        }
        // The LLM is *not* loaded at launch (2.5 GB for nothing if you don't dictate). It starts on your first
        // key press; with streaming, the first piece isn't cleaned until your first pause, which hides the load.
    }

    func activeLLM() -> TextLLM? {
        switch Settings.shared.llmBackend {
        case .apple: return AppleLLM.isAvailable ? AppleLLM() : nil
        case .llama: return llama
        case .auto: return AppleLLM.isAvailable ? AppleLLM() : llama
        }
    }

    // MARK: Hotkey state machine

    private func handle(_ e: HotkeyMonitor.Event) {
        switch e {
        case .triggerDown(let shift):
            if state == .recording {
                if pendingTapDiscard != nil, let t = lastShortTap, Date().timeIntervalSince(t) < doubleTapWindow {
                    // Second tap of a double-tap → hands-free.
                    pendingTapDiscard?.cancel(); pendingTapDiscard = nil
                    locked = true
                    overlay.show(phaseForRecording())
                } else if locked {
                    finish()
                }
                return
            }
            guard state == .idle else { return }
            begin(shift ? .command : .dictate)
        case .shiftWhileHeld:
            if state == .recording, !locked, mode == .dictate {
                mode = .command
                live?.onSegment = nil          // the speech is now an instruction, not text to polish
                cleaner?.cancelAll()
                cleaner = nil
                overlay.show(.command)
                if context.selectedText == nil { context = DictationContext.capture(includeSelection: true) }
                prewarmLLM()
            }
        case .triggerUp:
            guard state == .recording, !locked else { return }
            let held = Date().timeIntervalSince(pressTime)
            if held < tapThreshold {
                // Maybe the first half of a double-tap. Keep recording briefly; discard if no second tap comes.
                lastShortTap = Date()
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .recording, !self.locked else { return }
                    self.pendingTapDiscard = nil
                    self.cancel(silently: true)
                }
                pendingTapDiscard = w
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: w)
            } else {
                finish()
            }
        case .otherKeyWhileHeld:
            if state == .recording, !locked { cancel(silently: true) }
        case .escape:
            if state == .recording { cancel(silently: false) }
            else if state == .processing {
                // Changed your mind while it was finishing: drop the result.
                processingTask?.cancel(); processingTask = nil
                state = .idle
                overlay.show(.message("Cancelled", isError: false))
            }
        case .keyDown:
            break
        }
    }

    private func phaseForRecording() -> OverlayModel.Phase {
        switch mode {
        case .dictate: return .listening(locked: locked)
        case .command: return .command
        }
    }

    // MARK: Start

    private func begin(_ m: Mode) {
        mode = m
        locked = false
        pressTime = Date()
        context = DictationContext.capture(includeSelection: m == .command)
        do {
            try recorder.start()
        } catch {
            overlay.show(.message("Mic error: \(error.localizedDescription)", isError: true))
            return
        }
        state = .recording
        startLive()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            self.armWork = nil
            if Settings.shared.playSounds { Sound.shared.play(.start) }
            AudioDevices.duck()
            self.overlay.show(self.phaseForRecording())
            // The speech model may have been released while idle: reload it while the first words come in.
            let t = self.transcriber
            Task.detached(priority: .userInitiated) { try? await t.load() }
            self.prewarmLLM()
        }
        armWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }

    /// Streams the dictation: committed text + italic in-progress text in the notch, and (for dictation)
    /// LLM cleanup of each finished piece while you keep talking.
    private func startLive() {
        let showText = Settings.shared.liveCaption
        let l = LiveDictation(recorder: recorder, transcriber: transcriber, partials: showText)
        l.onTranscript = { [weak self] committed, partial in
            guard showText, let self, self.state == .recording || self.state == .processing else { return }
            self.overlay.model.setTranscript(committed: committed, partial: partial)
        }
        if mode == .dictate {
            let ctx = context
            let style = Settings.shared.style(for: ctx.category)
            let c = IncrementalCleaner(style: style, llm: activeLLM(), system: systemPrompt(for: ctx),
                                       beforeCursor: ctx.textBeforeCursor, timeout: Settings.shared.llmTimeoutSeconds)
            cleaner = c
            l.onSegment = { [weak c] raw, tight in c?.add(raw, tight: tight) }
        } else {
            cleaner = nil
        }
        live = l
        l.start()
    }

    private func prewarmLLM() {
        guard let llm = activeLLM() else { return }
        let sys: String
        let ex: [(String, String)]
        switch mode {
        case .command: sys = Prompts.commandSystem; ex = []
        case .dictate:
            guard Settings.shared.style(for: context.category).cleanup == .llm else { return }
            sys = systemPrompt(for: context); ex = Prompts.fewShot
        }
        Task.detached { await llm.prewarm(system: sys, examples: ex) }
    }

    // MARK: Stop

    private func cancel(silently: Bool) {
        armWork?.cancel(); armWork = nil
        pendingTapDiscard?.cancel(); pendingTapDiscard = nil
        live?.cancel(); live = nil
        cleaner?.cancelAll(); cleaner = nil
        _ = recorder.stop()
        AudioDevices.unduck()
        state = .idle
        locked = false
        if silently { overlay.hide() } else { overlay.show(.message("Cancelled", isError: false)) }
    }

    private func finish() {
        locked = false
        state = .processing
        let audio = recorder.stop()
        AudioDevices.unduck()
        if Settings.shared.playSounds { Sound.shared.play(.stop) }
        let mode = self.mode
        let ctx = self.context
        let seconds = Double(audio.count) / 16_000
        guard let live else { state = .idle; overlay.hide(); return }
        let cleaner = self.cleaner
        self.live = nil
        self.cleaner = nil
        armWork?.cancel(); armWork = nil
        overlay.show(.thinking)
        let t0 = Date()
        processingTask = Task {
            // Only the piece after your last pause is left to transcribe; earlier pieces are already cleaned.
            cleaner?.beginFinish()
            let segments = await live.finish(audio: audio)
            let raw = segments.joined(separator: " ")
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail(AudioRecorder.peak(audio) < 0.004 ? "Didn't hear anything — check your mic" : "No speech recognized")
            }
            let (_, send) = AutoSend.strip(raw)
            do {
                let final: String
                let engine: String
                if mode == .command {
                    (final, engine) = try await runCommand(instruction: AutoSend.strip(raw).0, ctx: ctx)
                } else if let cleaner {
                    if send { cleaner.transformLast { AutoSend.strip($0).0 } }
                    let joined = await cleaner.result()
                    (final, engine) = finishText(joined, ctx: ctx, engines: cleaner.engines)
                } else {
                    (final, engine) = await polish(AutoSend.strip(raw).0, ctx: ctx)
                }
                guard !Task.isCancelled else { return }
                guard !final.isEmpty else { state = .idle; overlay.hide(); return }
                deliver(final, raw: raw, ctx: ctx, mode: mode, engine: engine, seconds: seconds, t0: t0, send: send)
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
            }
        }
    }

    /// Snippets, dictionary spellings and tone on the joined, cleaned pieces.
    private func finishText(_ text: String, ctx: DictationContext, engines: Set<String>) -> (String, String) {
        let s = Settings.shared
        let style = s.style(for: ctx.category)
        let out = RuleCleaner.applyTone(RuleCleaner.expandSnippets(text, s.snippets), style.tone, keep: s.dictionary.map(\.term))
        let engine = engines.contains { $0 != "fast" && $0 != "raw" && !$0.contains("fallback") }
            ? (engines.first { !$0.contains("fast") && $0 != "raw" } ?? "llm") + " · streamed"
            : (engines.first ?? "fast") + " · streamed"
        return (out, engine)
    }

    private func fail(_ message: String) {
        state = .idle
        if Settings.shared.playSounds { Sound.shared.play(.error) }
        overlay.show(.message(message, isError: true))
    }

    private func deliver(_ final: String, raw: String, ctx: DictationContext, mode: Mode, engine: String,
                         seconds: Double, t0: Date, send: Bool) {
        let insertText = mode == .command || final.hasSuffix("\n") || send ? final : final + " "
        let result = TextInserter.insert(insertText, into: ctx.app, pressReturn: send)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        lastText = final
        lastRaw = raw
        History.shared.add(HistoryEntry(date: Date(), app: ctx.appName, raw: raw, final: final, audioSeconds: seconds,
                                        latencyMs: ms, engine: engine, mode: mode.rawValue, bundleID: ctx.bundleID))
        state = .idle
        switch result {
        case .pasted:
            if Settings.shared.playSounds { Sound.shared.play(.done) }
            overlay.show(.done(words: RuleCleaner.wordCount(final)))
            if Settings.shared.learnCorrections, mode != .command, let app = ctx.app {
                watcher.watch(final, in: app) { [weak self] found in self?.learn(found) }
            }
        case .copied(let reason):
            overlay.show(.message(reason, isError: false))
        }
    }

    private func learn(_ corrections: [LearnedCorrection]) {
        for c in corrections {
            Settings.shared.learn(term: c.corrected, heard: CorrectionLearner.isCommon(c.heard) ? c.corrected : c.heard)
        }
        if let first = corrections.first {
            // Never cover a live dictation with the toast; the word is saved either way.
            if state == .idle { overlay.show(.message("Learned “\(first.corrected)”", isError: false)) }
            Task { await transcriber.configureVocabulary(Settings.shared.dictionary) }
        }
    }

    // MARK: Cleanup

    private func systemPrompt(for ctx: DictationContext) -> String {
        let terms = Settings.shared.dictionary.map(\.term) + ctx.visibleNames
        return Prompts.cleanupSystem(category: Settings.shared.useAppContext ? ctx.category : .other, appName: ctx.appName,
                                     dictionary: Array(NSOrderedSet(array: terms)) as? [String] ?? terms,
                                     extra: Settings.shared.extraInstructions)
    }

    /// Dictation cleanup. Always produces something: falls back to rule-cleaned text if the LLM is
    /// unavailable, too slow, or returns something that doesn't look like a cleanup of what was said.
    private func polish(_ raw: String, ctx: DictationContext) async -> (String, String) {
        let s = Settings.shared
        let style = s.style(for: ctx.category)
        let keep = s.dictionary.map(\.term)
        func finish(_ t: String, _ engine: String) -> (String, String) {
            (RuleCleaner.applyTone(RuleCleaner.expandSnippets(t, s.snippets), style.tone, keep: keep), engine)
        }
        switch style.cleanup {
        case .off:
            return (RuleCleaner.expandSnippets(raw, s.snippets), "raw")
        case .rules:
            return finish(RuleCleaner.clean(RuleCleaner.applyDictionary(raw, s.dictionary)), "fast")
        case .llm:
            let ruled = RuleCleaner.clean(RuleCleaner.applyDictionary(raw, s.dictionary))
            // Short utterances ("sounds good", "thanks!") don't need an LLM — keep them instant.
            guard RuleCleaner.wordCount(ruled) > 4, let llm = activeLLM() else { return finish(ruled, "fast") }
            let maxTokens = min(2048, Int(Double(RuleCleaner.wordCount(raw)) * 2.5) + 64)
            do {
                let sys = systemPrompt(for: ctx)
                let user = Prompts.cleanupUser(RuleCleaner.applyDictionary(raw, s.dictionary), alreadyTyped: ctx.textBeforeCursor)
                let out = try await withTimeout(s.llmTimeoutSeconds) {
                    try await llm.complete(system: sys, examples: Prompts.fewShot, user: user, maxTokens: maxTokens)
                }
                let clean = OutputGuard.sanitize(out)
                if OutputGuard.looksValid(cleaned: clean, source: raw) { return finish(clean, llm.name) }
                NSLog("Vox: LLM output rejected by guard: \(clean)")
            } catch {
                NSLog("Vox: LLM cleanup failed: \(error)")
            }
            return finish(ruled, "fast (fallback)")
        }
    }

    /// Command mode: rewrite the selection per the spoken instruction, or write new text if nothing is selected.
    private func runCommand(instruction: String, ctx: DictationContext) async throws -> (String, String) {
        guard let llm = activeLLM() else { throw LLMError.unavailable("Command mode needs the local LLM") }
        var selection = ctx.selectedText
        if selection == nil { selection = await TextInserter.copySelectionViaClipboard() }
        let limit = max(Settings.shared.llmTimeoutSeconds * 4, 20)
        let out: String
        if let sel = selection, !sel.isEmpty {
            out = try await withTimeout(limit) {
                try await llm.complete(system: Prompts.commandSystem, examples: [],
                                       user: Prompts.commandUser(selection: sel, instruction: instruction),
                                       maxTokens: min(3000, sel.count / 2 + 400))
            }
        } else {
            out = try await withTimeout(limit) {
                try await llm.complete(system: Prompts.generateSystem, examples: [], user: instruction, maxTokens: 800)
            }
        }
        return (OutputGuard.sanitize(out), llm.name + " command")
    }

    // MARK: Utilities

    func pasteLast() {
        guard let t = lastText ?? History.shared.entries.first?.final else { return }
        TextInserter.insert(t, into: NSWorkspace.shared.frontmostApplication)
    }

    /// "Use original": paste exactly what you said, without the AI cleanup.
    func pasteLastOriginal() {
        guard let t = lastRaw ?? History.shared.entries.first?.raw else { return }
        TextInserter.insert(t, into: NSWorkspace.shared.frontmostApplication)
    }
}

extension Notification.Name {
    static let voxOpenSection = Notification.Name("voxOpenSection")
}

/// Runs `op` but gives up after `seconds` — *without waiting* for `op` to notice (a task group would block until
/// the loser finished, e.g. a model still loading). The loser is cancelled and abandoned.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    let result: T = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            gate.set(c)
            work = Task { do { gate.resume(.success(try await op())) } catch { gate.resume(.failure(error)) } }
            timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.resume(.failure(LLMError.unavailable("LLM timed out after \(seconds)s")))
            }
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
    work?.cancel(); timer?.cancel()
    return result
}

/// Resumes a continuation exactly once, from whichever side gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let r = early { early = nil; lock.unlock(); c.resume(with: r); return }
        continuation = c
        lock.unlock()
    }

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(with: r); return }
        early = r
        lock.unlock()
    }
}
