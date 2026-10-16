import AppKit
import SwiftUI

// MARK: - Models

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(locked: Bool)
        case command
        case thinking
        case done(words: Int)
        case message(String, isError: Bool)
    }
    @Published var phase: Phase = .hidden
    @Published private(set) var committed = ""
    @Published private(set) var partial = ""
    @Published private(set) var lines = 0               // visible transcript lines
    @Published var shake = 0

    static let textWidth: CGFloat = 488
    static let lineHeight: CGFloat = 18
    static let maxLines = 4
    private static let font = NSFont.systemFont(ofSize: 13.5)
    private static let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13.5), toHaveTrait: .italicFontMask)

    func reset() {
        committed = ""; partial = ""; lines = 0
    }

    /// Called ~1–2×/s while speaking. Measures wrapped lines once per update (cheap) so the island can size itself.
    func setTranscript(committed c: String, partial p: String) {
        guard c != committed || p != partial else { return }
        let s = NSMutableAttributedString(string: c, attributes: [.font: Self.font])
        if !p.isEmpty { s.append(NSAttributedString(string: (c.isEmpty ? "" : " ") + p, attributes: [.font: Self.italic])) }
        let h = s.length == 0 ? 0 : s.boundingRect(with: NSSize(width: Self.textWidth, height: 10_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let n = s.length == 0 ? 0 : min(Self.maxLines, max(1, Int((h / 16.5).rounded(.up))))
        committed = c; partial = p
        if n != lines { lines = n }
    }

}

/// The dot-matrix level meter's state. Separate from `OverlayModel` so 15 Hz level changes only redraw the
/// meter's Canvas, never the island or the transcript.
@MainActor
final class MeterModel: ObservableObject {
    static let columns = 9, rows = 5
    @Published private(set) var levels = [UInt8](repeating: 0, count: MeterModel.columns)
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        levels = [UInt8](repeating: 0, count: Self.columns)
        let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if levels.contains(where: { $0 > 0 }) { levels = [UInt8](repeating: 0, count: Self.columns) }
    }

    private func sample() {
        let v = LevelMeter.shared.value
        let q = UInt8(min(Double(Self.rows), (pow(Double(v), 0.6) * Double(Self.rows) * 1.25).rounded()))
        // Only publish when the picture changes (silence = no redraws at all).
        if q == 0, levels.allSatisfy({ $0 == 0 }) { return }
        var next = levels
        next.removeFirst()
        next.append(q)
        if next != levels { levels = next }
    }
}

// MARK: - Geometry

struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat      // in screen coordinates

    static func current() -> NotchGeometry {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(screen: screen, hasNotch: true, notchWidth: r.minX - l.maxX,
                                 notchHeight: screen.safeAreaInsets.top, centerX: screen.frame.minX + (l.maxX + r.minX) / 2)
        }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(screen: screen, hasNotch: false, notchWidth: 0, notchHeight: max(bar, 24), centerX: screen.frame.midX)
    }
}

/// The notch silhouette: concave flares melting into the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = bottomRadius
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Window

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the non-activating panel. Never steals focus from the field you're dictating into.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    let meter = MeterModel()
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var geometry = NotchGeometry.current()
    static let panelSize = CGSize(width: 640, height: 230)

    private static func isLive(_ p: OverlayModel.Phase) -> Bool {
        switch p { case .listening, .command: return true; default: return false }
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        // Swiped to another Space (or full-screen app) while the island is up: follow it there.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase != .hidden else { return }
                self.replacePanel()
                self.panel?.orderFrontRegardless()
            }
        }
    }

    func show(_ phase: OverlayModel.Phase) {
        hideWork?.cancel()
        let wasHidden = model.phase == .hidden
        // A new recording never inherits the last one's transcript (lock/shift switches keep it).
        if wasHidden || (Self.isLive(phase) && !Self.isLive(model.phase)) { model.reset() }
        // A fresh window every time the island opens. A long-lived panel stays tied to the Spaces it was first
        // shown on — each full-screen app has its own — and silently never appears on the others, even with
        // .canJoinAllSpaces + .fullScreenAuxiliary. A new one joins the Space you're on now.
        if wasHidden || panel == nil { replacePanel() }
        panel?.orderFrontRegardless()
        model.phase = phase
        switch phase {
        case .listening, .command: meter.start()
        default: meter.stop()
        }
        switch phase {
        case .done: scheduleHide(after: 0.9)
        case .message(_, let isError):
            if isError { model.shake += 1 }
            scheduleHide(after: isError ? 3.0 : 2.4)
        default: break
        }
    }

    func hide() { scheduleHide(after: 0) }

    private func scheduleHide(after s: Double) {
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.meter.stop()
            self.model.phase = .hidden
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                if self?.model.phase == .hidden { self?.panel?.orderOut(nil) }
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    /// Swaps in a new panel positioned on the current screen; the old one (if any) is ordered out and released.
    private func replacePanel() {
        let old = panel
        let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovable = false
        p.ignoresMouseEvents = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: root())
        panel = p
        position()
        old?.orderOut(nil)
    }

    private func root() -> OverlayRoot {
        OverlayRoot(model: model, meter: meter, geometry: geometry)
    }

    private func position() {
        geometry = NotchGeometry.current()
        guard let p = panel else { return }
        let f = geometry.screen.frame
        p.setFrame(NSRect(x: geometry.centerX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                          width: Self.panelSize.width, height: Self.panelSize.height), display: false)
        (p.contentView as? NSHostingView<OverlayRoot>)?.rootView = root()
    }
}

// MARK: - Views

struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    let meter: MeterModel
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            if geometry.hasNotch {
                Island(model: model, meter: meter, notch: CGSize(width: geometry.notchWidth, height: geometry.notchHeight), floating: false)
            } else {
                Island(model: model, meter: meter, notch: CGSize(width: 150, height: 30), floating: true)
                    .padding(.top, geometry.notchHeight + 6)
            }
            Spacer(minLength: 0)
        }
        .frame(width: OverlayController.panelSize.width, height: OverlayController.panelSize.height, alignment: .top)
    }
}

/// The island. On notched Macs it grows out of the hardware notch (pure black, so the seam disappears);
/// elsewhere it's a black capsule with a hairline, floating under the menu bar.
struct Island: View {
    @ObservedObject var model: OverlayModel
    let meter: MeterModel
    let notch: CGSize
    let floating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let wing: CGFloat = 64

    private var showsTranscript: Bool {
        switch model.phase {
        case .listening, .command, .thinking: return model.lines > 0
        default: return false
        }
    }

    /// Hands-free (double-tap) recording: the island says how to stop, since no key is being held.
    private var handsFree: Bool {
        switch model.phase {
        case .listening(true): return true
        default: return false
        }
    }
    private static let hintHeight: CGFloat = 26

    private var size: CGSize {
        let compact = CGSize(width: notch.width + wing * 2, height: notch.height)
        switch model.phase {
        case .hidden: return floating ? CGSize(width: notch.width, height: notch.height) : notch
        case .listening, .command, .thinking:
            let hint = handsFree ? Self.hintHeight : 0
            guard showsTranscript else {
                return handsFree ? CGSize(width: max(compact.width, 300), height: notch.height + hint) : compact
            }
            return CGSize(width: OverlayModel.textWidth + 36, height: notch.height + 10 + CGFloat(model.lines) * OverlayModel.lineHeight + 12 + hint)
        case .done: return compact
        case .message: return CGSize(width: max(compact.width, 420), height: notch.height + 30)
        }
    }

    var body: some View {
        let s = size
        let expanded = s.height > notch.height + 1
        let topR: CGFloat = floating ? 0 : (expanded ? 12 : 6)
        let botR: CGFloat = floating ? min(s.height / 2, 18) : (expanded ? 22 : 13)
        let hidden = model.phase == .hidden
        ZStack(alignment: .top) {
            if floating {
                RoundedRectangle(cornerRadius: botR, style: .continuous).fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: botR, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .frame(width: s.width, height: s.height)
            } else {
                NotchShape(topRadius: topR, bottomRadius: botR)
                    .fill(Color.black)
                    .frame(width: s.width + topR * 2, height: s.height)
            }
            content(size: s)
                .frame(width: s.width, height: s.height, alignment: .top)
                .clipped()
                .opacity(hidden ? 0 : 1)
                .animation(.easeOut(duration: 0.14).delay(hidden ? 0 : 0.06), value: hidden)
        }
        .modifier(Shake(shakes: CGFloat(model.shake)))
        .animation(.easeOut(duration: 0.3), value: model.shake)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : (hidden ? Motion.islandClose : Motion.islandOpen), value: s)
        .opacity(floating && hidden ? 0 : 1)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(size s: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: wing, height: notch.height)
                Spacer(minLength: 0)
                rightWing.frame(width: wing, height: notch.height)
            }
            .frame(width: floating ? s.width : notch.width + wing * 2, height: notch.height)
            below
        }
    }

    // Left wing: a mark whose *shape* says what's happening — no color needed.
    @ViewBuilder private var leftWing: some View {
        switch model.phase {
        case .listening(let locked):
            if locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.9)) }
            else { Circle().fill(Color.white).frame(width: 6, height: 6) }
        case .command:
            Image(systemName: "wand.and.stars").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        case .thinking:
            ThinkingDots()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        case .message(_, let isError):
            Image(systemName: isError ? "exclamationmark" : "doc.on.clipboard")
                .font(.system(size: 10.5, weight: .bold)).foregroundStyle(isError ? Color.alert : .white)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.phase {
        case .listening, .command:
            DotMatrixMeter(meter: meter)
        case .done(let words):
            Text("+\(words)").font(.mono(11, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(words)))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var below: some View {
        if showsTranscript {
            TranscriptView(model: model).padding(.top, 8).padding(.horizontal, 18)
        }
        if handsFree { HandsFreeHint().padding(.top, showsTranscript ? 6 : 2) }
        if case .message(let text, _) = model.phase {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).padding(.horizontal, 20).padding(.top, 5)
        }
    }
}

/// "esc cancel · fn done": static engraved keycaps (the keyboard version of a ✕ / ✓ pair).
struct HandsFreeHint: View {
    var body: some View {
        HStack(spacing: 14) {
            item("esc", "cancel")
            item(Settings.shared.trigger.keycap, "done")
        }
        .frame(height: 16)
    }

    private func item(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 16, minHeight: 15).padding(.horizontal, key.count > 1 ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.white.opacity(0.16)))
            Text(label.uppercased()).font(.mono(9)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Committed words solid; the words still being recognised in italic at 45 %. Shows the newest 3 lines,
/// older text scrolls up under a fade drawn in black (cheaper than a mask on a black island).
struct TranscriptView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let h = CGFloat(model.lines) * OverlayModel.lineHeight
        (Text(model.committed).foregroundColor(.white.opacity(0.92))
         + Text((model.committed.isEmpty || model.partial.isEmpty ? "" : " ") + model.partial)
            .italic().foregroundColor(.white.opacity(0.45)))
            .font(.system(size: 13.5))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: OverlayModel.textWidth, alignment: .leading)
            .frame(height: h, alignment: .bottom)
            .clipped()
            .overlay(alignment: .top) {
                if model.lines >= OverlayModel.maxLines {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.partial)
    }
}

/// 9×5 dot matrix scrolling the recent mic level — redraws only when the picture changes.
struct DotMatrixMeter: View {
    @ObservedObject var meter: MeterModel
    var body: some View {
        Canvas { ctx, size in
            let cols = MeterModel.columns, rows = MeterModel.rows
            let pitch: CGFloat = 4, dot: CGFloat = 2
            let w = CGFloat(cols - 1) * pitch + dot, h = CGFloat(rows - 1) * pitch + dot
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            for c in 0..<cols {
                let lit = Int(meter.levels[c])
                for r in 0..<rows {
                    let on = (rows - 1 - r) < max(1, lit)
                    let rect = CGRect(x: ox + CGFloat(c) * pitch, y: oy + CGFloat(r) * pitch, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(on ? (lit == 0 ? 0.35 : 0.95) : 0.13)))
                }
            }
        }
        .frame(width: 44, height: 22)
        .accessibilityHidden(true)
    }
}

/// Three dot-matrix dots stepping while the text is being finished (only exists for that short moment).
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.16)) { tl in
            let step = Int(tl.date.timeIntervalSinceReferenceDate / 0.16) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white.opacity(i == step ? 0.95 : 0.25)).frame(width: 3, height: 3)
                }
            }
        }
    }
}

/// macOS-password-field style shake for errors.
struct Shake: GeometryEffect {
    var amount: CGFloat = 4
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 6), y: 0))
    }
}
