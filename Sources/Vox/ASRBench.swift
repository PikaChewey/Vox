import FluidAudio
import Foundation

/// `Vox --asr-bench clip.wav`: wall time and *CPU* time per transcription for each Parakeet variant
/// (to pick the most battery-friendly default).
enum ASRBench {
    static func run(path: String) async {
        guard let audio = try? SelfTest.loadAudio(path) else { print("can't read \(path)"); return }
        let clip = Array(audio.prefix(16_000 * 8))
        for (name, v) in [("ultra", AsrModelVersion.ultra), ("v2", .v2), ("phonon2", .phonon2), ("v3", .v3)] {
            do {
                let models = try await AsrModels.downloadAndLoad(version: v)
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                var st = TdtDecoderState.make()
                _ = try await m.transcribe(clip, decoderState: &st)
                let c0 = processCPUSeconds(), t0 = Date()
                var text = ""
                for _ in 0..<15 {
                    var s = TdtDecoderState.make()
                    text = try await m.transcribe(clip, decoderState: &s).text
                }
                let wall = Date().timeIntervalSince(t0) / 15, cpu = (processCPUSeconds() - c0) / 15
                print(String(format: "%-8@ wall %5.0f ms  cpu %5.0f ms  | %@", name as NSString, wall * 1000, cpu * 1000, String(text.prefix(60))))
                await m.cleanup()
            } catch {
                print("\(name): \(error)")
            }
        }
    }
}
