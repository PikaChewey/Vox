import AppKit
import SwiftUI

/// `Vox --render-ui <dir>`: renders key views to PNGs in-process (design QA without screen capture).
@MainActor
enum RenderUI {
    static func run(_ dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let notched = NotchGeometry(screen: screen, hasNotch: true, notchWidth: 185, notchHeight: 32, centerX: 0)
        let flat = NotchGeometry(screen: screen, hasNotch: false, notchWidth: 0, notchHeight: 24, centerX: 0)

        typealias Setup = (OverlayModel) -> Void
        let states: [(String, OverlayModel.Phase, Setup)] = [
            ("1-listening", .listening(locked: false), { _ in }),
            ("2-live-1line", .listening(locked: false), { m in m.setTranscript(committed: "Can you make the login button green", partial: "and also add") }),
            ("3-live-3lines", .listening(locked: false), { m in
                m.setTranscript(committed: "So I want you to look at the navbar component in navbar.tsx. The dropdown is broken on mobile, it doesn't close when you tap outside. Can you fix that and make sure you don't break the desktop version,",
                                 partial: "and use the existing click outside hook if there is one")
            }),
            ("4-command", .command, { m in m.setTranscript(committed: "Make this more concise", partial: "and friendlier") }),
            ("6-thinking", .thinking, { m in m.setTranscript(committed: "Hey, are we still meeting at 6 tomorrow?", partial: "") }),
            ("7-done", .done(words: 42), { _ in }),
            ("9-handsfree", .listening(locked: true), { m in
                m.setTranscript(committed: "Okay so for the release notes, lead with the faster finish time,", partial: "then the new icon")
            }),
            ("8-error", .message("Didn't hear anything — check your mic", isError: true), { _ in }),
        ]
        for (name, phase, setup) in states {
            for (suffix, g) in [("notch", notched), ("flat", flat)] where suffix == "notch" || name.hasPrefix("2") {
                let m = OverlayModel()
                let meter = MeterModel()
                m.phase = phase
                setup(m)
                let v = OverlayRoot(model: m, meter: meter, geometry: g)
                    .frame(width: 640, height: 230)
                    .background(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                save(v, out.appendingPathComponent("overlay-\(name)-\(suffix).png"))
            }
        }
        save(ShareCardView(words: 48_213, wpm: 152, streak: 9, saved: 974), out.appendingPathComponent("share-card.png"), scale: 1)
        save(VoxMark(ink: .white).frame(width: 256, height: 256).background(Color.black), out.appendingPathComponent("mark.png"), scale: 1)
        let c = DictationController()
        for dark in [true, false] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            save(HomePage(controller: c, history: History.shared).padding(32).frame(width: 760).background(Color.canvas).environment(\.colorScheme, scheme),
                 out.appendingPathComponent("page-home-\(suffix).png"))
            save(SettingsPage(controller: c, settings: Settings.shared).padding(32).frame(width: 760).background(Color.canvas).environment(\.colorScheme, scheme),
                 out.appendingPathComponent("page-settings-\(suffix).png"))
            save(StylesPage(settings: Settings.shared).padding(32).frame(width: 760).background(Color.canvas).environment(\.colorScheme, scheme),
                 out.appendingPathComponent("page-styles-\(suffix).png"))
        }
        // History row with its change view open.
        let sample = HistoryEntry(date: Date(), app: "Slack", raw: "um so can you make the login button blue no wait green and uh also add a hover state",
                                  final: "Can you make the login button green and also add a hover state?", audioSeconds: 6, latencyMs: 410, engine: "llama")
        for dark in [true, false] {
            save(HistoryRow(entry: sample, showRaw: true).padding(20).frame(width: 640).background(Color.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light),
                 out.appendingPathComponent("history-changes-\(dark ? "dark" : "light").png"))
        }
        // Onboarding: welcome and key steps, illustrations at their final frame.
        IllustrationRender.resting = true
        for (i, name) in [(0, "welcome"), (2, "key")] {
            for dark in [true, false] {
                save(OnboardingView(controller: c, finish: {}, initialStep: i)
                        .environment(\.colorScheme, dark ? .dark : .light),
                     out.appendingPathComponent("onboarding-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        print("rendered to \(dir)")
    }

    static func save<V: View>(_ v: V, _ url: URL, scale: CGFloat = 2) {
        let r = ImageRenderer(content: v)
        r.scale = scale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("failed: \(url.lastPathComponent)"); return }
        try? png.write(to: url)
    }
}
