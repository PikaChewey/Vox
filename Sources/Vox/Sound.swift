import AVFoundation

/// Tiny synthesized cues (no audio files): a soft rising two-note on start, falling on stop, a tick when text
/// lands, a low muted thud on errors. Pre-rendered and played from a warm engine so there's zero latency.
final class Sound: @unchecked Sendable {
    static let shared = Sound()
    enum Cue { case start, stop, done, error }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var started = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers[.start] = render([(784, 0.07), (1175, 0.11)], gain: 0.09)     // G5 → D6
        buffers[.stop] = render([(1175, 0.06), (784, 0.10)], gain: 0.08)      // D6 → G5
        buffers[.done] = render([(1568, 0.045)], gain: 0.05)                  // G6 tick
        buffers[.error] = render([(196, 0.16)], gain: 0.12, soft: true)       // G3 thud
    }

    private func render(_ notes: [(Double, Double)], gain: Float, soft: Bool = false) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let total = notes.reduce(0) { $0 + Int($1.1 * sr) }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        let out = buf.floatChannelData![0]
        var i = 0
        for (freq, dur) in notes {
            let n = Int(dur * sr)
            for k in 0..<n {
                let t = Double(k) / sr
                // Quick attack, exponential decay; a touch of 2nd harmonic for warmth.
                let env = min(1, t / 0.004) * exp(-t / (dur * (soft ? 0.45 : 0.32)))
                let s = sin(2 * .pi * freq * t) + 0.18 * sin(4 * .pi * freq * t)
                out[i + k] = Float(s * env) * gain
            }
            i += n
        }
        return buf
    }

    func play(_ cue: Cue) {
        guard Settings.shared.playSounds, let b = buffers[cue] else { return }
        if !started {
            do { try engine.start(); started = true } catch { return }
        }
        player.scheduleBuffer(b, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        // Let the audio hardware sleep again when we're quiet (saves power).
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.player.stop(); self.engine.pause(); self.started = false
        }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }
    private var idle: DispatchWorkItem?
}
