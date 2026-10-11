import SwiftUI

/// Design QA renders (`--render-ui`) show illustrations at their resting (final) frame.
enum IllustrationRender { nonisolated(unsafe) static var resting = false }

/// The welcome hero: the notch grows into the island and your words stream in — committed text solid,
/// the word still being recognised in italic. Plays once.
struct WelcomeIsland: View {
    @State private var start = Date()
    @State private var playing = !IllustrationRender.resting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let words = ["Hey,", "are", "you", "free", "to", "talk", "at", "six", "tonight?"]
    private let duration = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { tl in
            let t = playing ? min(tl.date.timeIntervalSince(start), duration) : duration
            let open = min(1, max(0, (t - 0.25) / 0.35))
            let e = open * open * (3 - 2 * open)
            let shown = max(0, min(words.count, Int((t - 0.6) / 0.24)))
            let committed = words.prefix(max(0, shown - 1)).joined(separator: " ")
            let partial = shown > 0 && t < duration - 0.3 ? words[shown - 1] : ""
            let finalText = t >= duration - 0.3 ? words.prefix(shown).joined(separator: " ") : committed
            let width = 150 + (440 - 150) * e
            let height = 32 + 30 * e
            ZStack(alignment: .top) {
                NotchShape(topRadius: 6 + 6 * e, bottomRadius: 13 + 9 * e).fill(Color.black)
                    .frame(width: width + (12 + 12 * e), height: height)
                VStack(spacing: 4) {
                    HStack {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                        Spacer()
                        DemoMeter(t: t).frame(width: 44, height: 22)
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 22)
                    (Text(finalText).foregroundColor(.white.opacity(0.92))
                     + Text((finalText.isEmpty || partial.isEmpty ? "" : " ") + partial).italic().foregroundColor(.white.opacity(0.45)))
                        .font(.system(size: 13.5))
                        .lineLimit(1)
                }
                .frame(width: width, height: height, alignment: .top)
                .opacity(e)
                .clipped()
            }
            .frame(height: 70, alignment: .top)
            .onChange(of: t >= duration) { _, done in if done { playing = false } }
        }
        .onAppear { start = Date(); playing = !reduceMotion && !IllustrationRender.resting }
        .contentShape(Rectangle())
        .onTapGesture { start = Date(); playing = !reduceMotion }
        .accessibilityHidden(true)
    }
}

private struct DemoMeter: View {
    var t: Double
    var body: some View {
        Canvas { ctx, size in
            let cols = 9, rows = 5, pitch: CGFloat = 4, dot: CGFloat = 2
            let ox = (size.width - CGFloat(cols - 1) * pitch - dot) / 2, oy = (size.height - CGFloat(rows - 1) * pitch - dot) / 2
            for c in 0..<cols {
                let v = t < 3.0 ? (sin(t * 9 + Double(c) * 0.8) * 0.5 + 0.5) * (0.4 + 0.6 * sin(t * 2.3 + Double(c)) * sin(t * 2.3 + Double(c))) : 0
                let lit = max(1, Int(v * Double(rows) + 0.5))
                for r in 0..<rows {
                    let on = (rows - 1 - r) < lit
                    ctx.fill(Path(ellipseIn: CGRect(x: ox + CGFloat(c) * pitch, y: oy + CGFloat(r) * pitch, width: dot, height: dot)),
                             with: .color(.white.opacity(on ? 0.95 : 0.13)))
                }
            }
        }
    }
}
