import AVFoundation
import Foundation

/// `Vox --transcribe file.wav [AppName]` runs the full pipeline headlessly and prints timings.
/// Handy for checking models and prompts without touching the mic or the hotkey.
enum SelfTest {
    static func run(path: String, app: String?) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let samples = try load(path)
                let t = Transcriber()
                var t0 = Date()
                try await t.load()
                print("asr load: \(ms(t0)) ms")
                await t.configureVocabulary(Settings.shared.dictionary)
                t0 = Date()
                let raw = try await t.transcribe(samples)
                let asrMs = ms(t0)
                print("asr: \(asrMs) ms for \(String(format: "%.1f", Double(samples.count) / 16000)) s audio\nRAW:   \(raw)")
                print("RULES: \(RuleCleaner.clean(raw))")
                let llama = LlamaServer()
                let llm: TextLLM = AppleLLM.isAvailable && Settings.shared.llmBackend != .llama ? AppleLLM() : llama
                let cat = AppCategory.classify(bundleID: nil, appName: app)
                let sys = Prompts.cleanupSystem(category: cat, appName: app, dictionary: Settings.shared.dictionary.map(\.term),
                                                extra: Settings.shared.extraInstructions)
                await llm.prewarm(system: sys, examples: Prompts.fewShot)
                t0 = Date()
                let out = try await llm.complete(system: sys, examples: Prompts.fewShot, user: Prompts.wrapTranscript(raw), maxTokens: 512)
                let clean = OutputGuard.sanitize(out)
                print("LLM (\(llm.name), \(cat)): \(ms(t0)) ms, guard=\(OutputGuard.looksValid(cleaned: clean, source: raw))\n\(clean)")
                print("total after key-up ≈ \(asrMs + ms(t0)) ms")
                await llama.stop()
            } catch {
                print("error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    /// `Vox --test-text`: quick checks of the deterministic text logic.
    static func text() {
        func show(_ label: String, _ v: String) { print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) → \(v)") }
        show("tone casual", RuleCleaner.applyTone("Hey, are you around for dinner tonight? Let's do 7.", .casual, keep: []))
        show("tone very casual", RuleCleaner.applyTone("Hey, are you free? I think Priya and NASA said yes. Sounds good.", .veryCasual, keep: ["Priya"]))
        show("auto-send", "\(AutoSend.strip("Run the tests and fix any failures, press enter."))")
        show("auto-send (none)", "\(AutoSend.strip("Tell them to press the enter key twice"))")
        show("scratch that", RuleCleaner.clean("send it to john. no scratch that send it to mike"))
        show("filler + stutter", RuleCleaner.clean("um so the the button is uh broken"))
        show("dictionary", RuleCleaner.applyDictionary("deploy it on versel with super base", Settings.shared.dictionary))
        MainActor.assumeIsolated {
            show("join: list", IncrementalCleaner.join(["Okay, so for the auth page I need three things.", "1. Add Google sign in\n2. Store the session in Supabase", "3. Redirect to /dashboard after login."]).replacingOccurrences(of: "\n", with: " ⏎ "))
            show("join: continue (and)", IncrementalCleaner.join(["She focused on stem cell research.", "and Alzheimer's research."]))
            show("join: continue (comma)", IncrementalCleaner.join(["In addition to serving our nation.", "she was a passionate advocate."]))
            show("join: question", IncrementalCleaner.join(["Is it done?", "yes it is."]))
            show("join: new sentence", IncrementalCleaner.join(["With the love of her life.", "Ronald Reagan, whom she married."]))
            show("join: mid-sentence capital", IncrementalCleaner.join(["We need to", "Fix the build before Friday."]))
            show("join: tight cut", IncrementalCleaner.join(["As president, I know just how.", "Important it is to have a partner."], tight: [1]))
            show("decapitalize", IncrementalCleaner.decapitalized("Important it is") + " / " + IncrementalCleaner.decapitalized("Reagan was") + " / " + IncrementalCleaner.decapitalized("I am"))
            show("join: after list", IncrementalCleaner.join(["1. One\n2. Two", "Thanks."]).replacingOccurrences(of: "\n", with: " ⏎ "))
            func pause(_ a: String, _ b: String) -> String {
                let k = Boundary.kind(after: a, before: b)
                return "\(k)" + (k == .ends ? "" : " → " + Boundary.soften(a, b, kind: k))
            }
            show("pause: dangling word", pause("So I was thinking that we should.", "Probably move it to Thursday."))
            show("pause: comma", pause("I really like the colors,", "But the spacing is tight."))
            show("pause: sentence end", pause("I finished the report this morning.", "Can you review it?"))
            show("pause: unsure", pause("The app thinks.", "The sentence is over."))
            show("pause: '?' at a cut", pause("Can you update the README so that it?", "Explains how to install it."))
            show("pause: list item", pause("I need three things:", "1. Add sign in."))
            show("split finished", IncrementalCleaner.splitFinished("First fix the login bug on the settings page. Then deploy to staging and").map { "\($0.head) | \($0.tail)" } ?? "nil")
            show("split (one sentence)", IncrementalCleaner.splitFinished("So we should probably move it because Friday is a holiday.").map { "\($0.head) | \($0.tail)" } ?? "nil")
        }
    }

    private static func ms(_ d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }

    static func loadAudio(_ path: String) throws -> [Float] { try load(path) }

    private static func load(_ path: String) throws -> [Float] {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: inBuf)
        let conv = AVAudioConverter(from: f.processingFormat, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(f.length) * 16_000 / f.processingFormat.sampleRate) + 1024)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
