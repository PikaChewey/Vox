import Foundation
import FluidAudio

/// Parakeet TDT on the Apple Neural Engine via FluidAudio. The live segmenter feeds it short pause-bounded
/// segments (≤15 s, ~50–120 ms each on the ANE), so finishing a long dictation only costs the last segment.
/// The model is released after 10 idle minutes and reloaded in the background on the next key press
/// (≈0.2–0.5 s, hidden behind the first words you speak).
actor Transcriber {
    private var idleUnload: Task<Void, Never>?
    static let idleSeconds: UInt64 = 600
    private var manager: AsrManager?
    private var loadedVersion: ASRModelChoice?
    private var boosting: VocabularyBoostingSession?
    private var boostingTerms: [DictionaryTerm] = []
    private var ctcModels: CtcModels?
    private var loading: Task<Void, Error>?
    private(set) var status = "not loaded"

    private func fluidVersion(_ c: ASRModelChoice) -> AsrModelVersion {
        switch c {
        case .ultra: return .ultra
        case .v2: return .v2
        case .v3: return .v3
        }
    }

    var isReady: Bool { manager != nil && loadedVersion == Settings.shared.asrModel }

    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        let choice = Settings.shared.asrModel
        if manager != nil, loadedVersion == choice { return }
        if let t = loading { try await t.value; return }
        let t = Task {
            status = "downloading/compiling \(choice.rawValue)…"
            progress?(status)
            let models = try await AsrModels.downloadAndLoad(version: fluidVersion(choice))
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
            loadedVersion = choice
            touch()
            // Warm the ANE graph so the first real dictation is as fast as the rest.
            _ = try? await transcribeRaw([Float](repeating: 0, count: 16_000))
            status = "ready"
            progress?(status)
        }
        loading = t
        defer { loading = nil }
        try await t.value
    }

    /// Rebuild CTC vocabulary boosting when the personal dictionary changes.
    func configureVocabulary(_ terms: [DictionaryTerm]) async {
        guard Settings.shared.vocabularyBoosting, !terms.isEmpty else {
            boosting = nil; boostingTerms = []; ctcModels = nil   // free the ~100 MB CTC model too
            return
        }
        if terms == boostingTerms, boosting != nil { return }
        do {
            if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m) }
            guard let ctc = ctcModels else { return }
            let ctx = CustomVocabularyContext(terms: terms.map {
                CustomVocabularyTerm(text: $0.term, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
            })
            boosting = try await VocabularyBoostingSession(vocabulary: ctx, ctcModels: ctc)
            boostingTerms = terms
        } catch {
            NSLog("Vox: vocabulary boosting unavailable: \(error)")
            boosting = nil
        }
    }

    private func transcribeRaw(_ samples: [Float]) async throws -> ASRResult {
        guard let m = manager else { throw LLMError.unavailable("Speech model not loaded") }
        var state = TdtDecoderState.make()
        return try await m.transcribe(samples, decoderState: &state)
    }

    /// Partial (volatile) text for the segment still being spoken. No vocabulary pass. nil if the model
    /// isn't loaded yet — partials are best-effort.
    func partial(_ samples: [Float]) async -> String? {
        guard manager != nil, samples.count >= 8_000 else { return nil }
        var s = samples.count > ASRLimits.maxSamples ? Array(samples.suffix(ASRLimits.maxSamples)) : samples
        if s.count < 16_000 { s += [Float](repeating: 0, count: 16_000 - s.count) }
        touch()
        return try? await transcribeRaw(AudioRecorder.normalized(s)).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Releases the model after a quiet spell. Rescheduled on every use, so there's no periodic wakeup.
    private func touch() {
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() async {
        guard loading == nil, let m = manager else { return }
        await m.cleanup()
        manager = nil
        loadedVersion = nil
        status = "sleeping"
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await load()
        touch()
        // Parakeet wants ≥1 s; pad short clips with silence.
        var s = samples
        if s.count < 16_000 { s += [Float](repeating: 0, count: 16_000 - s.count) }
        let r = try await transcribeRaw(s)
        var text = r.text
        if let b = boosting, let timings = r.tokenTimings,
           let out = await b.rescore(text: text, tokenTimings: timings, audioSamples: s) {
            text = out.text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ASRLimits {
    /// Parakeet's encoder window is 15 s; longer audio is chunked internally (slower, slightly worse).
    static let maxSamples = 16_000 * 15
}
