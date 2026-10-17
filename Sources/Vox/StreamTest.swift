import AVFoundation
import AppKit
import Foundation

/// `Vox --stream-test speech.wav [AppName] [speed]` — plays a recording through the *live* pipeline
/// (segmenter → Parakeet → incremental LLM cleanup) at real-time pace, then "releases the key" and reports:
/// the transcript timeline, time from release to final text, and the process's average CPU while streaming.
@MainActor
enum StreamTest {
    static func run(path: String, app: String?, speed: Double) async {
        do {
            let audio = try SelfTest.loadAudio(path)
            let recorder = AudioRecorder()
            let transcriber = Transcriber()
            let llama = LlamaServer()
            try await transcriber.load()
            let cat = AppCategory.classify(bundleID: nil, appName: app)
            let style = Settings.shared.style(for: cat)
            let sys = Prompts.cleanupSystem(category: cat, appName: app, dictionary: Settings.shared.dictionary.map(\.term),
                                            extra: Settings.shared.extraInstructions)
            let llm: TextLLM? = style.cleanup == .llm ? (AppleLLM.isAvailable && Settings.shared.llmBackend != .llama ? AppleLLM() as TextLLM : llama as TextLLM) : nil
            if let llm { await llm.prewarm(system: sys, examples: Prompts.fewShot) }

            let live = LiveDictation(recorder: recorder, transcriber: transcriber,
                                     partials: ProcessInfo.processInfo.environment["VOX_NO_PARTIALS"] == nil)
            if ProcessInfo.processInfo.environment["VOX_VAD_TRACE"] != nil { live.trace = { print($0) } }
            let cleaner = IncrementalCleaner(style: style, llm: llm, system: sys, beforeCursor: nil, timeout: Settings.shared.llmTimeoutSeconds)
            let t0 = Date()
            var updates = 0
            var lastPrint = ""
            live.onTranscript = { committed, partial in
                updates += 1
                let line = String(format: "%6.1fs │ %@ %@", Date().timeIntervalSince(t0),
                                  String(committed.suffix(70)), partial.isEmpty ? "" : "⟨\(partial.suffix(40))⟩")
                if line != lastPrint { print(line); lastPrint = line }
            }
            live.onSegment = { raw, tight in
                print(String(format: "%6.1fs ■ committed%@: %@", Date().timeIntervalSince(t0), tight ? " (tight)" : "", raw))
                cleaner.add(raw, tight: tight)
            }
            live.onReplaceLast = { raw in
                print(String(format: "%6.1fs ■ re-heard with the previous: %@", Date().timeIntervalSince(t0), raw))
                cleaner.replaceLast(raw)
            }
            let cpu0 = cpuSeconds()
            live.start()
            // Feed 100 ms chunks at (speed ×) real time.
            let chunk = 1_600
            var i = 0
            while i < audio.count {
                recorder.feed(Array(audio[i..<min(i + chunk, audio.count)]))
                i += chunk
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 / speed))
            }
            let streamed = Date().timeIntervalSince(t0)
            let cpuStream = cpuSeconds() - cpu0
            // Release.
            let release = Date()
            let all = recorder.stopFeeding()
            cleaner.beginFinish()
            let segments = await live.finish(audio: all)
            let asrDone = Date().timeIntervalSince(release)
            let text = await cleaner.result()
            let total = Date().timeIntervalSince(release)
            print("\n── release ──")
            print(String(format: "audio %.1f s · %d segments · %d live updates", Double(audio.count) / 16_000, segments.count, updates))
            print(String(format: "release → last segment transcribed: %.0f ms", asrDone * 1000))
            print(String(format: "release → final cleaned text:       %.0f ms  (engines: %@)", total * 1000, cleaner.engines.sorted().joined(separator: ", ")))
            print(String(format: "Vox CPU while streaming: %.1f%% of one core (%.2f s CPU over %.1f s, includes ASR scheduling; LLM runs in llama-server)",
                         100 * cpuStream / streamed, cpuStream, streamed))
            print("\nRAW:\n\(segments.joined(separator: " "))\n\nFINAL:\n\(text)")
            await llama.stop()
        } catch {
            print("error: \(error)")
        }
    }

    static func cpuSeconds() -> Double { processCPUSeconds() }

    /// `Vox --mic-test speech.wav out.txt` — the REAL capture path: AVAudioEngine mic → recorder → live pipeline,
    /// while the clip plays through the speakers. Prints the live timeline, key-up→text latency and CPU to out.txt.
    static func mic(path: String, out: String) async {
        freopen(out, "w", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        let recorder = AudioRecorder()
        let transcriber = Transcriber()
        let llama = LlamaServer()
        do {
            try await transcriber.load()
            let style = Settings.shared.style(for: .notes)
            let sys = Prompts.cleanupSystem(category: .notes, appName: "Notes", dictionary: Settings.shared.dictionary.map(\.term),
                                            extra: "")
            await llama.prewarm(system: sys, examples: Prompts.fewShot)
            let live = LiveDictation(recorder: recorder, transcriber: transcriber, partials: true)
            if ProcessInfo.processInfo.environment["VOX_VAD_TRACE"] != nil { live.trace = { print($0) } }
            let cleaner = IncrementalCleaner(style: style, llm: llama, system: sys, beforeCursor: nil, timeout: 4)
            let t0 = Date()
            var updates = 0, partialUpdates = 0
            live.onTranscript = { c, p in
                updates += 1
                if !p.isEmpty { partialUpdates += 1 }
                print(String(format: "%5.1fs │ %@ %@", Date().timeIntervalSince(t0), String(c.suffix(60)), p.isEmpty ? "" : "⟨\(p.suffix(40))⟩"))
            }
            live.onSegment = { raw, tight in cleaner.add(raw, tight: tight) }
            live.onReplaceLast = { raw in cleaner.replaceLast(raw) }
            try recorder.start()
            print("mic: \(recorder.deviceName)")
            live.start()
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.7", path]
            try player.run()
            let cpu0 = processCPUSeconds()
            while player.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let listened = Date().timeIntervalSince(t0)
            let cpu = processCPUSeconds() - cpu0
            let release = Date()
            let audio = recorder.stop()
            cleaner.beginFinish()
            let segments = await live.finish(audio: audio)
            let text = await cleaner.result()
            saveWAV(audio, to: out + ".wav")   // replay offline: --stream-test <out>.wav
            print("\n── key released ──")
            print(String(format: "captured %.1f s from the real mic · peak %.3f · %d segments · %d live updates (%d with in-progress text)",
                         Double(audio.count) / 16_000, AudioRecorder.peak(audio), segments.count, updates, partialUpdates))
            print(String(format: "key-up → final cleaned text: %.0f ms", Date().timeIntervalSince(release) * 1000))
            print(String(format: "Vox CPU while listening: %.1f%% of one core", 100 * cpu / listened))
            print("\nFINAL:\n\(text)")
        } catch {
            print("error: \(error)")
        }
        await llama.stop()
        fflush(stdout)
    }
}

/// 16 kHz mono float WAV (test captures only).
func saveWAV(_ samples: [Float], to path: String) {
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
          let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings) else { return }
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try? file.write(from: buf)
}

/// Total user+system CPU time of this process (for efficiency measurements).
func processCPUSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}
