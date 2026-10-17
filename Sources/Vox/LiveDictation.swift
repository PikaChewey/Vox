import Accelerate
import Foundation

/// Streams a dictation while you speak.
///
/// Every 250 ms it reads the new 20 ms energy frames from the recorder (no audio is re-scanned) and runs a
/// tiny voice-activity detector with an adaptive noise floor. When you pause (≥ 0.44 s) it *commits* the
/// segment since the last pause: Parakeet transcribes that piece exactly once, and the piece is handed to
/// the incremental cleaner so the LLM polishes it while you keep talking. Long stretches without a pause
/// are cut at the quietest moment before 14 s (Parakeet's window is 15 s).
///
/// For the piece you're still speaking it runs a cheap partial transcription about every 0.6 s, shown as
/// italic, translucent text. When you release the key only the final piece is left to transcribe and
/// clean, so finishing a 2-minute monologue costs about the same as finishing a 5-second one.
@MainActor
final class LiveDictation {
    /// (committed text, in-progress text) — called on the main actor ~1–2×/s while speaking.
    var onTranscript: ((String, String) -> Void)?
    /// Each committed raw segment, in order (the incremental cleaner subscribes here). `tight` = the cut fell
    /// mid-phrase (a word was heard on both sides), so the piece continues the previous one with no punctuation.
    var onSegment: ((_ raw: String, _ tight: Bool) -> Void)?
    /// The last segment was re-heard together with the one after it (a pause that didn't end the sentence):
    /// this text replaces it, and the newer segment is not delivered on its own.
    var onReplaceLast: ((_ raw: String) -> Void)?
    /// Test-only VAD trace (`VOX_VAD_TRACE=1`): one line per tick.
    var trace: ((String) -> Void)?

    private let recorder: AudioRecorder
    private let transcriber: Transcriber
    private var timer: DispatchSourceTimer?

    private var regionStart = 0             // first sample of the uncommitted region
    private var regionRMS: [Float] = []     // energy frames of the uncommitted region
    private var analyzedFrames = 0
    private var noise: Float = 0.003
    private var threshold: Float = 0.008
    private var recent: [Float] = []
    private var silentRun = 0
    private var voicedInRegion = 0
    private var voicedSincePartial = 0
    private var lastPartialSample = 0
    private var partialInFlight = false
    private var generation = 0              // bumps on every commit; stale partials are dropped

    private(set) var segments: [String] = []
    private var ranges: [Range<Int>] = []   // where each segment sits in the recording
    private var fullAudio: [Float]?         // the whole recording, once the key is up
    private var displaySegments: [String] = []
    private var partial = ""
    /// Previews of segments that were committed but whose final text hasn't arrived yet (~100 ms) — kept on
    /// screen so words never blink out between "still recognizing" and "final".
    private var carried: [Int: String] = [:]
    private var commitIndex = 0
    private var chain: Task<Void, Never>?   // serial ASR work, in order

    // Tunables (20 ms frames).
    private let pauseFrames = 22            // 0.44 s of silence ends a long segment
    private let longPauseFrames = 35        // 0.7 s for segments under 5 s
    private let keepSilenceFrames = 16      // keep 0.32 s of the pause in the segment
    private let minVoicedFrames = 30        // ≥ 0.6 s of speech before a pause can commit
    private let minSegmentSamples = Int(1.6 * 16_000)
    private let forceSamples = 14 * 16_000
    /// Partials get rarer as the segment grows (each one re-reads the whole segment): 0.65 s → ~1.6 s.
    private func partialInterval(_ regionSamples: Int) -> Int {
        Int((0.65 + 0.07 * Double(regionSamples) / 16_000) * 16_000)
    }

    /// Partials only exist to be displayed: with the live transcript off they're skipped entirely.
    private let partials: Bool

    init(recorder: AudioRecorder, transcriber: Transcriber, partials: Bool = true) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.partials = partials
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway lets macOS coalesce these wakeups with others (battery).
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(60))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    func cancel() {
        timer?.cancel(); timer = nil
        chain?.cancel()
    }

    // MARK: Segmentation

    private func tick() {
        let frames = recorder.frames(from: analyzedFrames)
        guard !frames.isEmpty else { return }
        for rms in frames {
            // Levels from the last 3 s, re-read every 0.5 s: the noise floor is the 10th percentile and the speech
            // level the 90th. The threshold sits a fifth of the way from floor to speech (at least 2.4× the floor),
            // so it follows the mic: a quiet laptop mic across the room and a headset both segment cleanly.
            recent.append(rms)
            if recent.count > 150 { recent.removeFirst(recent.count - 150) }
            if analyzedFrames % 25 == 0 || recent.count < 25 {
                let sorted = recent.sorted()
                noise = max(0.0004, sorted[sorted.count / 10])
                threshold = max(noise * 2.4 + 0.0003, noise + 0.2 * (sorted[sorted.count * 9 / 10] - noise))
            }
            let voiced = rms > threshold
            if voiced { silentRun = 0; voicedInRegion += 1; voicedSincePartial += 1 } else { silentRun += 1 }
            regionRMS.append(rms)
            analyzedFrames += 1
        }
        let now = analyzedFrames * AudioRecorder.frame
        let regionLength = now - regionStart
        trace?(String(format: "%6.2fs vad noise %.4f thr %.4f rms %.4f…%.4f silent %d voicedΣ %d sincePartial %d%@",
                      Double(now) / 16_000, noise, threshold, frames.min() ?? 0, frames.max() ?? 0,
                      silentRun, voicedInRegion, voicedSincePartial, partialInFlight ? " (partial in flight)" : ""))

        // Short segments need a longer pause before committing (fewer mid-sentence cuts); long ones commit
        // at any natural pause so the work keeps flowing.
        let needed = regionLength < 5 * 16_000 ? longPauseFrames : pauseFrames
        if silentRun >= needed, voicedInRegion >= minVoicedFrames, regionLength >= minSegmentSamples {
            commit(upTo: now - (silentRun - keepSilenceFrames) * AudioRecorder.frame)
        } else if regionLength >= forceSamples {
            commit(upTo: quietestCut())
        } else if partials, voicedSincePartial >= 12, now - lastPartialSample >= partialInterval(regionLength), !partialInFlight {
            requestPartial(upTo: now)
        }
    }

    /// The quietest 20 ms frame between 9 s and the end of the region — the least likely place for a word.
    private func quietestCut() -> Int {
        let lo = min(regionRMS.count - 1, 9 * 50), hi = max(lo, regionRMS.count - 15)
        var best = hi, bestE = Float.greatestFiniteMagnitude
        for i in lo...hi {
            let e = regionRMS[max(0, i - 2)...min(regionRMS.count - 1, i + 2)].reduce(0, +)
            if e < bestE { bestE = e; best = i }
        }
        return regionStart + best * AudioRecorder.frame
    }

    private func commit(upTo cut: Int) {
        let range = regionStart..<max(regionStart, cut)
        trace?(String(format: "commit %.2f–%.2f s", Double(range.lowerBound) / 16_000, Double(range.upperBound) / 16_000))
        let consumedFrames = range.count / AudioRecorder.frame
        regionRMS.removeFirst(min(consumedFrames, regionRMS.count))
        regionStart = range.upperBound
        voicedInRegion = 0
        voicedSincePartial = 0
        lastPartialSample = regionStart
        generation += 1
        commitIndex += 1
        if !partial.isEmpty { carried[commitIndex] = partial }
        partial = ""
        let samples = recorder.slice(range)
        enqueueFinal(samples, range: range, index: commitIndex)
    }

    private func audio(_ r: Range<Int>) -> [Float] {
        guard let a = fullAudio else { return recorder.slice(r) }
        return Array(a[r.clamped(to: 0..<a.count)])
    }

    /// Parakeet's window is 15 s; a re-heard pair stays inside it.
    private static let rejoinSamples = 14 * 16_000

    /// A segment heard alone loses its edges: Parakeet ends it with a period, and a word just before the pause
    /// comes out wrong ("…the app and" → "the appan."). When the pause didn't end the sentence and both segments
    /// fit in one window, hear them again as one — with the pause inside, Parakeet punctuates across it correctly.
    private func rejoin(_ text: String, range: Range<Int>, gate: Float) async -> (String, Range<Int>)? {
        guard let prev = segments.last, let prevRange = ranges.last, Boundary.kind(after: prev, before: text) != .ends else { return nil }
        let both = prevRange.lowerBound..<range.upperBound
        guard both.count <= Self.rejoinSamples else { return nil }
        let trimmed = AudioRecorder.trimSilence(audio(both), threshold: gate)
        guard trimmed.count > 16_000 / 4, let t = try? await transcriber.transcribe(AudioRecorder.normalized(trimmed)),
              !t.isEmpty, !Task.isCancelled else { return nil }
        // Sanity: the pair must still hold (nearly) all the words of both halves.
        let expected = RuleCleaner.wordCount(prev) + RuleCleaner.wordCount(text)
        guard RuleCleaner.wordCount(t) * 10 >= expected * 7 else { return nil }
        return (t, both)
    }

    private func enqueueFinal(_ samples: [Float], range: Range<Int>, index: Int) {
        let prev = chain
        let transcriber = self.transcriber
        // Trim only what is clearly room noise: quiet words can sit at ~1–2× the floor (a real-mic test lost
        // "was as lucky as I am" to a fixed 0.004 trim). Silence costs Parakeet a few ms; a lost word costs trust.
        let gate = min(0.003, max(0.0006, noise * 1.25))
        chain = Task { [weak self] in
            await prev?.value
            let trimmed = AudioRecorder.trimSilence(samples, threshold: gate)
            var text: String?
            if trimmed.count > 16_000 / 4, AudioRecorder.peak(trimmed) > max(0.003, gate * 2) {
                text = try? await transcriber.transcribe(AudioRecorder.normalized(trimmed))
            }
            guard let self else { return }
            guard let text, !text.isEmpty, !Task.isCancelled else { self.carried[index] = nil; self.publish(); return }
            if let (joined, both) = await self.rejoin(text, range: range, gate: gate) {
                self.carried[index] = nil
                self.replaceLast(joined, range: both)
            } else {
                self.carried[index] = nil
                self.append(text, range: range)
            }
        }
    }

    /// What the notch shows for segment `i`: no period or capital at a thinking pause. May edit segment i−1's text.
    private func shown(_ raw: String, at i: Int) -> String {
        var shown = RuleCleaner.clean(raw)
        if i > 0, Boundary.kind(after: segments[i - 1], before: raw) != .ends {
            let prevShown = displaySegments[i - 1]
            if let l = prevShown.last, ".?".contains(l), !prevShown.hasSuffix("..") { displaySegments[i - 1].removeLast() }
            shown = IncrementalCleaner.decapitalized(shown)
        }
        return shown
    }

    private func replaceLast(_ raw: String, range: Range<Int>) {
        let i = segments.count - 1
        segments[i] = raw
        ranges[i] = range
        displaySegments[i] = shown(raw, at: i)
        publish()
        onReplaceLast?(raw)
    }

    private func append(_ raw0: String, range: Range<Int>) {
        var raw = raw0
        var tight = false
        // A cut can land inside a word, so both sides hear it ("…just how." + "How important…"): drop the echo.
        if let prev = segments.last {
            func norm(_ w: Substring?) -> String { (w.map(String.init) ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let last = norm(prev.split(separator: " ").last), first = norm(raw.split(separator: " ").first)
            if !first.isEmpty, first == last, first.count > 1 {
                tight = true
                raw = raw.split(separator: " ").dropFirst().joined(separator: " ")
                if let f = raw.first, f.isUppercase, prev.last.map({ !".!?".contains($0) }) ?? true {
                    raw = raw.prefix(1).lowercased() + raw.dropFirst()
                }
            }
        }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { publish(); return }
        // The live transcript doesn't end a sentence at a thinking pause either.
        let text = shown(raw, at: segments.count)
        segments.append(raw)
        ranges.append(range)
        displaySegments.append(text)
        publish()
        onSegment?(raw, tight)
    }

    private func requestPartial(upTo now: Int) {
        partialInFlight = true
        voicedSincePartial = 0
        lastPartialSample = now
        let gen = generation
        let samples = recorder.slice(regionStart..<now)
        let prev = chain
        let transcriber = self.transcriber
        chain = Task { [weak self] in
            await prev?.value
            let text = await transcriber.partial(samples)
            guard let self else { return }
            self.partialInFlight = false
            if gen == self.generation, let text, !text.isEmpty {
                self.partial = RuleCleaner.clean(text)
                self.publish()
            }
        }
    }

    private func publish() {
        let pendingPreview = carried.keys.sorted().compactMap { carried[$0] }
        onTranscript?(displaySegments.joined(separator: " "), (pendingPreview + [partial]).filter { !$0.isEmpty }.joined(separator: " "))
    }

    // MARK: Finish

    /// Stops listening, transcribes whatever is left, and returns every segment's raw text in order.
    /// `audio` is the full recording (from `recorder.stop()`).
    func finish(audio: [Float]) async -> [String] {
        timer?.cancel(); timer = nil
        generation += 1
        partial = ""
        fullAudio = audio
        // The tail after the last commit is often just the room (you stopped talking, then let go): only transcribe
        // it if some of it rises above the noise floor, or Parakeet may "hear" a word in the hum ("Yeah.").
        if regionStart < audio.count, Self.hasSpeech(audio[regionStart...], above: noise * 1.6) {
            trace?(String(format: "final %.2f–%.2f s", Double(regionStart) / 16_000, Double(audio.count) / 16_000))
            commitIndex += 1
            enqueueFinal(Array(audio[regionStart...]), range: regionStart..<audio.count, index: commitIndex)
        }
        await chain?.value
        publish()
        return segments
    }

    /// ≥ 0.12 s of 20 ms frames above `level`.
    private static func hasSpeech(_ s: ArraySlice<Float>, above level: Float) -> Bool {
        var loud = 0
        s.withUnsafeBufferPointer { p in
            var i = 0
            while i + AudioRecorder.frame <= p.count {
                var e: Float = 0
                vDSP_svesq(p.baseAddress! + i, 1, &e, vDSP_Length(AudioRecorder.frame))
                if (e / Float(AudioRecorder.frame)).squareRoot() > level { loud += 1 }
                i += AudioRecorder.frame
            }
        }
        return loud >= 6
    }
}

/// What a pause between two committed segments means. Parakeet hears each segment on its own, so it ends every
/// one with a period and capitalizes the next: a pause to think ("we should… probably move it") looks exactly
/// like a full stop. A pause is not evidence, so this decides from the words on either side.
enum Boundary {
    enum Kind { case continues, ends, unsure }

    /// Words a sentence almost never ends on ("…we should", "…because", "…to be", "…look at the").
    private static let dangling: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "from", "with", "into", "onto", "about", "as", "than",
        "and", "or", "but", "nor", "because", "since", "although", "though", "unless", "until", "if", "when", "while",
        "where", "whether", "that", "which", "who", "whose", "whom", "my", "your", "our", "their", "his", "her", "its",
        "is", "are", "was", "were", "be", "been", "being", "am", "will", "would", "can", "could", "should", "shall",
        "may", "might", "must", "do", "does", "did", "has", "had", "not", "very", "really", "just", "i", "we", "they",
        "he", "she", "going", "gonna", "wanna", "gotta", "some", "every", "each", "such", "making", "getting",
        "trying", "um", "uh", "er",
    ]
    /// First words that carry on whatever came before.
    private static let continuing: Set<String> = [
        "and", "or", "but", "nor", "of", "to", "with", "for", "in", "on", "at", "by", "from", "as", "which", "who",
        "whom", "whose", "that", "than", "because", "while", "when", "where", "if", "into", "about", "plus", "unless",
        "until", "since", "though", "although", "whether",
    ]
    /// First words that usually open a new sentence.
    private static let starters: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "we", "we're", "we've", "we'll", "you", "you're", "you'll", "they", "they're",
        "he", "she", "it's", "there", "there's", "here's", "this", "that's", "so", "okay", "ok", "also", "thanks",
        "thank", "please", "can", "could", "would", "will", "do", "does", "did", "is", "are", "let's", "let", "hey", "hi", "hello", "yeah", "yes", "no", "nope", "sure", "now", "next", "first",
        "second", "third", "finally", "anyway", "anyways", "oh", "well", "alright", "great", "cool", "nice", "sorry",
        "maybe", "hopefully", "honestly", "basically", "otherwise", "meanwhile", "however", "after", "before",
    ]

    private static func bare(_ w: Substring?) -> String {
        (w.map(String.init) ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(["'"]))
    }

    static func kind(after prev: String, before next: String) -> Kind {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines), n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = p.last, let start = n.first else { return .ends }
        if ",;-–—".contains(end) { return .continues }
        // A list item or a list intro keeps its own line.
        if end == ":" || n.range(of: #"^(?:\d+[.)]|[-•*])\s"#, options: .regularExpression) != nil { return .ends }
        if dangling.contains(bare(p.split(separator: " ").last)) { return .continues }
        let first = bare(n.split(separator: " ").first)
        if start.isLowercase || continuing.contains(first) { return .continues }
        // Even "?" at a cut is a guess ("Can you update the README so that it?" + "Explains how…"): it only ends the
        // sentence when the next words clearly start a new one.
        if starters.contains(first) { return .ends }
        return .unsure
    }

    /// Joins two raw segments across a pause: drops the period Parakeet put at the cut and the capital it gave the
    /// next word. A "?" is dropped only for a clear continuation; when unsure, it stays for the model to weigh.
    static func soften(_ prev: String, _ next: String, kind: Kind) -> String {
        var p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let marks: String = kind == .continues ? ".?!" : "."
        if let l = p.last, marks.contains(l), !p.hasSuffix("..") { p.removeLast() }
        if let l = p.last, !"?!".contains(l) { n = IncrementalCleaner.decapitalized(n) }
        return p + " " + n
    }
}

/// Polishes committed segments with the LLM *while you're still talking*, so key-up only waits for the last
/// piece. Each piece sees the already-cleaned text before it (so lists keep numbering and sentences continue)
/// and is guarded independently; any piece that fails falls back to the instant rule-based cleanup.
@MainActor
final class IncrementalCleaner {
    private struct Piece {
        var raw: String
        var task: Task<String, Never>
        /// Continues the previous piece mid-phrase: joined with a plain space, never a period or comma.
        var tight = false
    }

    private let style: StylePreset
    private let llm: TextLLM?
    private let system: String
    private let beforeCursor: String?
    private let timeout: Double
    private var pieces: [Piece] = []
    /// A tiny fragment waiting to be joined with the next piece.
    private var pending: String?
    /// How the last `add` changed things, so `replaceLast` can take it back: piece count and pending before it,
    /// the piece it merged away (if any), and its `tight` flag.
    private var lastAdd: (count: Int, pending: String?, removed: Piece?, tight: Bool)?
    /// Pieces just taken off the end, still running: a re-launch of the same text at the same place reuses one
    /// (a re-heard segment usually repeats the finished sentences before it word for word). The rest are cancelled.
    private var stale: [(index: Int, key: String, piece: Piece)] = []

    private static func reuseKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    private func stash(_ p: Piece) {
        stale.append((pieces.count, Self.reuseKey(p.raw), p))
    }

    private func dropStale() {
        for s in stale { s.piece.task.cancel() }
        stale.removeAll()
    }

    /// "Finished sentences. Open one" → ("Finished sentences.", "Open one"): splits at the last sentence end Parakeet
    /// heard inside the text (with the audio on both sides, so it's reliable), keeping both halves worth an LLM call.
    static func splitFinished(_ text: String) -> (head: String, tail: String)? {
        guard !text.contains("\n"), text.range(of: #"(?:^|\s)(?:\d+[.)]|[-•*])\s"#, options: .regularExpression) == nil else { return nil }
        let ends = try! NSRegularExpression(pattern: #"(?<=[a-z0-9\)"'’]{2})[.!?]\s+(?=[A-Z])"#)
        let ns = text as NSString
        for m in ends.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let head = ns.substring(to: m.range.location + 1).trimmingCharacters(in: .whitespaces)
            let tail = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
            if RuleCleaner.wordCount(head) >= 4, RuleCleaner.wordCount(tail) >= 3 { return (head, tail) }
        }
        return nil
    }
    private var finishing = false
    private(set) var engines = Set<String>()

    private static let correctionStart = try! NSRegularExpression(
        pattern: #"^\s*(?:no\b[,.!\s]|nope\b|actually\b|wait\b|sorry\b|i mean\b|scratch that\b|make (?:that|it)\b|or rather\b|correction\b|rather\b)"#,
        options: [.caseInsensitive])

    init(style: StylePreset, llm: TextLLM?, system: String, beforeCursor: String?, timeout: Double) {
        self.style = style
        self.llm = style.cleanup == .llm ? llm : nil
        self.system = system
        self.beforeCursor = beforeCursor
        self.timeout = timeout
    }

    /// A committed segment arrived: clean it right away (while you keep talking).
    func add(_ raw: String, tight: Bool = false) {
        var removed: Piece?
        let before = (count: pieces.count, pending: pending, tight: tight)
        defer { lastAdd = (before.count, before.pending, removed, before.tight); dropStale() }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var tight = tight
        if let p = pending { text = p + " " + text; pending = nil; tight = false }
        guard !text.isEmpty else { return }
        // Tiny fragments make poor LLM inputs. One that continues the last sentence ("and Alzheimer's research")
        // joins the piece before it; anything else ("okay so…") waits for the next piece.
        if !finishing, RuleCleaner.wordCount(text) < 4 {
            if let last = pieces.last, tight || Self.continues(text) {
                removed = pieces.removeLast()
                stash(last)
                launch(last.raw + " " + text, tight: last.tight)
            } else {
                pending = text
            }
            return
        }
        // "…at 5" / "actually no, 6": a correction that starts a piece rewrites the piece before it. A tiny final
        // tail ("the footer.") also joins the piece before it rather than becoming its own sentence.
        let isCorrection = Self.correctionStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        if let last = pieces.last, isCorrection || (finishing && RuleCleaner.wordCount(text) < 4) {
            removed = pieces.removeLast()
            stash(last)
            text = last.raw + " " + text
            tight = last.tight
        } else if let last = pieces.last {
            // Be slow to end a sentence at a pause. Unless the words say it ended ("…this morning." + "Can you…"),
            // the two pieces are cleaned together, so the model sees the whole sentence instead of two halves
            // that each get a period. With no LLM, only a clear continuation is merged (the rules can't re-punctuate).
            let kind = Boundary.kind(after: last.raw, before: text)
            let merge = kind == .continues || (kind == .unsure && llm != nil)
            if merge, RuleCleaner.wordCount(last.raw) + RuleCleaner.wordCount(text) <= Self.mergeWords {
                removed = pieces.removeLast()
                stash(last)
                text = Boundary.soften(last.raw, text, kind: kind)
                tight = last.tight
            } else if kind == .continues {
                // Too long to merge: still joined mid-sentence, with no period at the cut.
                tight = true
                text = Self.decapitalized(text)
            }
        }
        // Finished sentences go first as their own piece, so key-up only waits on the sentence still open.
        if removed != nil || !stale.isEmpty, let (head, tail) = Self.splitFinished(text) {
            launch(head, tight: tight)
            launch(tail)
        } else {
            launch(text, tight: tight)
        }
    }

    /// The segment last passed to `add` was re-heard together with the next one: undo that `add` and add this instead.
    func replaceLast(_ raw: String) {
        guard let snap = lastAdd else { add(raw); return }
        lastAdd = nil
        let keep = snap.count - (snap.removed == nil ? 0 : 1)
        while pieces.count > keep { stash(pieces.removeLast()) }
        if let r = snap.removed { launch(r.raw, tight: r.tight) }
        pending = snap.pending
        add(raw, tight: snap.tight)
    }

    /// Merged pieces stop growing here (about two long sentences) so key-up never waits on a huge piece.
    private static let mergeWords = 60

    private static let continuationWords: Set<String> = ["and", "or", "but", "nor", "of", "to", "with", "for", "in", "on",
        "at", "by", "from", "as", "which", "who", "whom", "whose", "that", "than", "because", "then", "while", "when",
        "where", "if", "into", "about", "like", "plus"]

    /// Does this fragment carry on the previous sentence?
    static func continues(_ text: String) -> Bool {
        guard let first = text.split(separator: " ").first else { return false }
        if first.first?.isLowercase == true { return true }
        return continuationWords.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    /// Call when the key comes up: from now on even short fragments are cleaned immediately.
    func beginFinish() { finishing = true }

    private func launch(_ source: String, tight: Bool = false) {
        let key = Self.reuseKey(source)
        if let i = stale.firstIndex(where: { $0.index == pieces.count && $0.key == key }) {
            var p = stale.remove(at: i).piece
            p.raw = source
            p.tight = tight
            pieces.append(p)
            return
        }
        let previous = pieces.last?.task
        let earlier = pieces.map(\.task)
        let earlierTight = Self.tightIndices(pieces)
        let task = Task { [weak self] () -> String in
            _ = await previous?.value      // keep LLM calls ordered; each one sees the cleaned text before it
            guard let self else { return RuleCleaner.clean(source) }
            var before: [String] = []
            for t in earlier { before.append(await t.value) }
            // Replaced (correction merge, "press enter" strip, mode switch): never touch the LLM for a discarded piece.
            if Task.isCancelled { return RuleCleaner.clean(source) }
            // A pause isn't always a sentence end. Hide the previous piece's final period so the model can
            // continue the sentence (it then starts in lowercase, and `join` drops that period).
            var context = Self.join(before, tight: earlierTight)
            if context.hasSuffix("."), !context.hasSuffix("..") { context.removeLast() }
            let out = await self.clean(source, alreadyTyped: context)
            // Parakeet capitalizes sentence starts, so a piece it began in lowercase is mid-sentence even if the
            // model capitalized it; lowercasing lets `join` merge it into the sentence before.
            return source.first?.isLowercase == true ? Self.decapitalized(out) : out
        }
        pieces.append(Piece(raw: source, task: task, tight: tight))
    }

    private static func tightIndices(_ pieces: [Piece]) -> Set<Int> {
        Set(pieces.indices.filter { pieces[$0].tight })
    }

    /// "Important it is…" → "important it is…" (leaves "I", acronyms and names alone).
    nonisolated static func decapitalized(_ t: String) -> String {
        guard let first = t.split(separator: " ").first.map(String.init), first.first?.isUppercase == true, first != "I",
              !first.hasPrefix("I'"), first.dropFirst().allSatisfy({ !$0.isUppercase }),
              Words.isReal(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) else { return t }
        return t.prefix(1).lowercased() + t.dropFirst()
    }

    /// Rewrites the most recent raw text (e.g. strips a spoken "press enter").
    func transformLast(_ f: (String) -> String) {
        if let p = pending {
            let t = f(p).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = t.isEmpty ? nil : t
            return
        }
        guard let last = pieces.popLast() else { return }
        last.task.cancel()
        let t = f(last.raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { launch(t, tight: last.tight) }
    }

    var lastRaw: String? { pending ?? pieces.last?.raw }

    /// Abandons all work (the dictation turned into a command, or was cancelled).
    func cancelAll() {
        for p in pieces { p.task.cancel() }
        pieces.removeAll()
        pending = nil
    }

    /// Waits for every piece and joins them.
    func result() async -> String {
        // A leftover fragment goes through the same merge rules (e.g. a final "no, six").
        if let p = pending { pending = nil; finishing = true; add(p) }
        var out: [String] = []
        for p in pieces { out.append(await p.task.value) }
        var text = Self.join(out, tight: Self.tightIndices(pieces))
        // Close the last sentence if the final piece trailed off without punctuation.
        if let l = text.last, l.isLetter || l.isNumber, RuleCleaner.wordCount(text) >= 3,
           !(text.split(separator: "\n").last.map { $0.range(of: #"^\s*(?:\d+[.)]|[-•*])\s"#, options: .regularExpression) != nil } ?? false) {
            text += "."
        }
        // Starting a sentence (empty field, or after "." / "?" / a newline): capitalize, even if the first piece
        // was cut mid-sentence. Text continuing a sentence before the cursor stays as it is.
        let before = (beforeCursor ?? "").trimmingCharacters(in: .whitespaces)
        if before.isEmpty || ".!?\n".contains(before.last!), let f = text.first, f.isLowercase {
            text = f.uppercased() + text.dropFirst()
        }
        return text
    }

    private func clean(_ raw: String, alreadyTyped: String) async -> String {
        let s = Settings.shared
        let ruled = RuleCleaner.clean(RuleCleaner.applyDictionary(raw, s.dictionary))
        switch style.cleanup {
        case .off: engines.insert("raw"); return raw
        case .rules: engines.insert("fast"); return ruled
        case .llm:
            guard let llm, RuleCleaner.wordCount(ruled) > 3 else { engines.insert("fast"); return ruled }
            let context = [beforeCursor ?? "", alreadyTyped].joined(separator: alreadyTyped.isEmpty ? "" : "\n")
            let user = Prompts.cleanupUser(RuleCleaner.applyDictionary(raw, s.dictionary),
                                           alreadyTyped: context.isEmpty ? nil : context)
            let maxTokens = min(1024, Int(Double(RuleCleaner.wordCount(raw)) * 2.5) + 48)
            do {
                let sys = system
                let out = try await withTimeout(timeout) {
                    try await llm.complete(system: sys, examples: Prompts.fewShot, user: user, maxTokens: maxTokens)
                }
                guard !Task.isCancelled else { return ruled }
                let clean = OutputGuard.sanitize(out)
                if OutputGuard.looksValid(cleaned: clean, source: raw) {
                    engines.insert(llm.name)
                    return clean
                }
                NSLog("Vox: piece rejected by guard: \(clean)")
            } catch {
                NSLog("Vox: piece cleanup failed: \(error)")
            }
            engines.insert("fast (fallback)")
            return ruled
        }
    }

    /// Joins cleaned pieces: continues sentences, keeps numbered lists on their own lines, and turns the
    /// sentence that introduces a list into "…:".
    static func join(_ parts: [String], tight: Set<Int> = []) -> String {
        var out = ""
        let listItem = try! NSRegularExpression(pattern: #"^\s*(?:\d+[.)]|[-•*])\s"#)
        func isList(_ s: String) -> Bool { listItem.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        for (i, raw) in parts.enumerated() {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty { out = t; continue }
            if tight.contains(i) {
                // The cut fell mid-phrase ("I know just how" | "important it is"): no period, no comma.
                if out.hasSuffix("."), !out.hasSuffix("..") { out.removeLast() }
                if let l = out.last, !"!?:\n".contains(l) { t = decapitalized(t) }
                out += " " + t
                continue
            }
            let lastLine = out.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? out
            if isList(t) {
                if !isList(lastLine), out.hasSuffix(".") { out.removeLast(); out += ":" }
                out += "\n" + t
            } else if isList(lastLine) {
                out += "\n\n" + t
            } else {
                if out.hasSuffix("."), !out.hasSuffix(".."), let f = t.first, f.isLowercase {
                    // The model continued the previous sentence across the pause: merge them.
                    out.removeLast()
                    let first = t.split(separator: " ").first.map { $0.lowercased() } ?? ""
                    // "which/who/whom" are left out: after a pause they open an aside ("Ronald Reagan, whom she married").
                    // Auxiliaries continue the subject before them ("President Reagan" + "was as lucky"): no comma either.
                    let joiners: Set<String> = ["and", "or", "but", "so", "of", "to", "with", "for", "in", "on", "at", "by",
                                                "from", "as", "that", "than", "because", "was", "were", "is", "are", "has",
                                                "have", "had", "will", "would", "can", "could", "should", "may", "might",
                                                "must", "do", "does", "did",
                                                "then", "while", "when", "where", "if", "into", "about", "like"]
                    // No comma after a dangling function word ("we need to" + "fix the build").
                    let lastWord = out.split(separator: " ").last.map { $0.lowercased() } ?? ""
                    let dangling: Set<String> = ["to", "the", "a", "an", "of", "and", "or", "but", "with", "for", "in", "on",
                                                 "at", "by", "from", "my", "your", "our", "their", "his", "her", "is", "are",
                                                 "was", "were", "be", "that", "this", "these", "those", "it", "we", "i", "you"]
                    out += (joiners.contains(first) || dangling.contains(lastWord)) ? " " + t : ", " + t
                    continue
                } else if let l = out.last, "!?:".contains(l), let f = t.first, f.isLowercase {
                    t = t.prefix(1).uppercased() + t.dropFirst()
                } else if let l = out.last, !".!?:\n".contains(l), let first = t.split(separator: " ").first.map(String.init),
                          first.first?.isUppercase == true, first != "I", !first.hasPrefix("I'"),
                          first.dropFirst().allSatisfy({ !$0.isUppercase }), Words.isReal(first.lowercased()) {
                    // The previous piece ended mid-sentence: don't start this one with a capital.
                    t = t.prefix(1).lowercased() + t.dropFirst()
                }
                out += " " + t
            }
        }
        return out
    }
}
