import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os

/// The mic level for the waveform. Written on the audio thread, read by the overlay's 30 fps Canvas —
/// no main-thread hops and no SwiftUI invalidation per buffer.
final class LevelMeter: @unchecked Sendable {
    static let shared = LevelMeter()
    private let state = OSAllocatedUnfairLock(initialState: Float(0))
    var value: Float { state.withLock { $0 } }
    func push(_ raw: Float) {
        // Fast attack, slow release: lively without jitter.
        state.withLock { v in v = raw > v ? v + (raw - v) * 0.6 : v + (raw - v) * 0.15 }
    }
    func reset() { state.withLock { $0 = 0 } }
}

/// Captures the chosen mic as 16 kHz mono Float32 — exactly what Parakeet wants. The engine only runs
/// while you're dictating (no always-on mic, no orange dot when idle).
///
/// Alongside the samples it keeps one RMS value per 20 ms frame, which the live segmenter uses to find
/// pauses without ever re-scanning audio.
final class AudioRecorder: @unchecked Sendable {
    static let frame = 320   // 20 ms at 16 kHz

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var frameRMS: [Float] = []
    private var pendingSquares: Float = 0      // sum of squares of the partial frame at the end
    private var pendingCount = 0
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var isRecording = false
    private(set) var deviceName = ""
    private var currentDevice: AudioDeviceID = 0

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples = []
        samples.reserveCapacity(16_000 * 20)     // grows if needed; never keeps a long session's peak
        frameRMS = []
        pendingSquares = 0; pendingCount = 0
        lock.unlock()
        LevelMeter.shared.reset()

        let input = engine.inputNode
        // Record from the chosen mic (by default: never a Bluetooth headset mic).
        if let dev = AudioDevices.chosenInput(), dev.id != currentDevice {
            try? input.auAudioUnit.setDeviceID(dev.id)
            currentDevice = dev.id
            deviceName = dev.name
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Vox", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        converter = AVAudioConverter(from: inFormat, to: target)
        input.removeTap(onBus: 0)
        // ~43 ms buffers at 48 kHz: plenty for a 30 fps meter and far fewer wakeups than tiny buffers.
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.consume(buf)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let chunk = UnsafeBufferPointer(start: ch, count: n)

        ingest(chunk)
    }

    /// Test hook: feed 16 kHz samples as if they came from the mic (used by `--stream-test`).
    func feed(_ s: [Float]) {
        if !isRecording {
            lock.lock(); samples.removeAll(); frameRMS.removeAll(); pendingSquares = 0; pendingCount = 0; lock.unlock()
            isRecording = true
        }
        s.withUnsafeBufferPointer { ingest($0) }
    }

    func stopFeeding() -> [Float] {
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let s = samples
        samples = []; frameRMS = []
        return s
    }

    private func ingest(_ chunk: UnsafeBufferPointer<Float>) {
        guard let ch = chunk.baseAddress else { return }
        let n = chunk.count
        var total: Float = 0
        vDSP_svesq(ch, 1, &total, vDSP_Length(n))
        LevelMeter.shared.push(min(1, sqrt(total / Float(n)) * 12))

        lock.lock()
        samples.append(contentsOf: chunk)
        // Per-20 ms RMS for the segmenter (carry the partial frame across buffers).
        var i = 0
        while i < n {
            let take = min(Self.frame - pendingCount, n - i)
            var sq: Float = 0
            vDSP_svesq(ch + i, 1, &sq, vDSP_Length(take))
            pendingSquares += sq
            pendingCount += take
            i += take
            if pendingCount == Self.frame {
                frameRMS.append(sqrt(pendingSquares / Float(Self.frame)))
                pendingSquares = 0; pendingCount = 0
            }
        }
        lock.unlock()
    }

    /// Stops capture and returns the whole utterance.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        LevelMeter.shared.reset()
        // Hand the buffer over (no copy, no lingering 1–10 MB after the dictation).
        lock.lock(); defer { lock.unlock() }
        let s = samples
        samples = []
        frameRMS = []
        pendingSquares = 0; pendingCount = 0
        return s
    }

    /// Number of samples captured so far.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// A copy of just `range` (clamped) — the segmenter never copies the whole recording.
    func slice(_ range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lo = max(0, min(range.lowerBound, samples.count)), hi = max(lo, min(range.upperBound, samples.count))
        return Array(samples[lo..<hi])
    }

    /// RMS per 20 ms frame for frames `from...` (frame i covers samples i*320 ..< (i+1)*320).
    func frames(from start: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return start < frameRMS.count ? Array(frameRMS[max(0, start)...]) : []
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frameRMS.count
    }

    /// Copy of everything captured so far.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16_000
    }

    /// Trims leading/trailing silence so the model doesn't hallucinate on dead air.
    static func trimSilence(_ s: [Float], threshold: Float = 0.006) -> [Float] {
        let win = frame
        guard s.count > win * 4 else { return s }
        func energy(_ i: Int) -> Float {
            let end = min(i + win, s.count)
            var e: Float = 0
            s.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &e, vDSP_Length(end - i)) }
            return sqrt(e / Float(end - i))
        }
        var start = 0
        while start + win < s.count, energy(start) < threshold { start += win }
        var end = s.count
        while end - win > start, energy(end - win) < threshold { end -= win }
        // Keep 200 ms of padding on each side.
        start = max(0, start - 3_200)
        end = min(s.count, end + 3_200)
        return start < end ? Array(s[start..<end]) : []
    }

    static func peak(_ s: [Float]) -> Float {
        var m: Float = 0
        s.withUnsafeBufferPointer { if let b = $0.baseAddress { vDSP_maxmgv(b, 1, &m, vDSP_Length(s.count)) } }
        return m
    }

    /// Quiet speech (far from the mic, or soft-spoken) comes in low; bring it up to a normal level (max 12×) so the speech model hears it.
    static func normalized(_ s: [Float]) -> [Float] {
        let p = peak(s)
        guard p > 0.0005, p < 0.35 else { return s }
        var g = min(12, 0.5 / p)
        var out = [Float](repeating: 0, count: s.count)
        vDSP_vsmul(s, 1, &g, &out, 1, vDSP_Length(s.count))
        return out
    }
}
