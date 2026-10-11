import AppKit
import SwiftUI

// MARK: - Ink (same family as Tutto: monochrome, hairlines, color only as an event)

extension Color {
    /// Text and marks. Black in light mode, white in dark mode.
    static let ink = Color.primary
    static let ink2 = Color.primary.opacity(0.80)
    static let ink3 = Color.primary.opacity(0.62)
    static let ink4 = Color.primary.opacity(0.40)
    static let hairline = Color.primary.opacity(0.12)
    static let wash = Color.primary.opacity(0.055)

    /// Ink that ignores vibrancy, for solid fills.
    static let solidInk = Color(nsColor: NSColor(name: "voxSolidInk") { $0.isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.07, alpha: 1) })
    /// The opposite of ink, for marks drawn on solid ink.
    static let paper = Color(nsColor: NSColor(name: "voxPaper") { $0.isDark ? .black : .white })
    /// Window background: off-black / off-white, never pure.
    static let canvas = Color(nsColor: NSColor(name: "voxCanvas") { $0.isDark ? NSColor(white: 0.04, alpha: 1) : NSColor(white: 0.98, alpha: 1) })
    /// The only non-ink color, reserved for real problems.
    static let alert = Color(nsColor: .systemRed)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Motion (nothing exceeds 0.45 s; exits ≈ 0.7× entrances; no bounce over 0.05)

enum Motion {
    static let micro = Animation.spring(duration: 0.20, bounce: 0)
    static let snappy = Animation.spring(duration: 0.28, bounce: 0.05)
    static let smooth = Animation.spring(duration: 0.40, bounce: 0)
    static let press = Animation.easeOut(duration: 0.12)
    /// The notch island growing out of the hardware notch, and folding back into it.
    static let islandOpen = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let islandClose = Animation.spring(response: 0.28, dampingFraction: 1.0)
}

// MARK: - Type

/// Small uppercase monospaced label, like an engraving on an instrument.
struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Color.ink3)
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Layout

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Color.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A group of rows on a faint surface with hairline separators — the only "card" Vox uses.
struct InkGroup<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Caption(title) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.wash.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
        }
    }
}

/// Caption on the left, a control on the right; hairline under it unless it's the last row.
struct LabeledRow<Content: View>: View {
    var title: String
    var detail: String?
    var last = false
    @ViewBuilder var content: Content

    init(_ title: String, detail: String? = nil, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.last = last
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Color.ink)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { if !last { Hairline().opacity(0.6) } }
        .accessibilityElement(children: .combine)   // VoiceOver: "Sounds, switch, on"
    }
}

/// Big monospaced number with an engraved caption.
struct Readout: View {
    var caption: String
    var value: String
    var unit: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(caption)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink3) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Keys

/// A key drawn as an engraved keycap.
struct Keycap: View {
    let label: String
    var large = false
    var body: some View {
        Text(label)
            .font(.system(size: large ? 13 : 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Color.ink2)
            .frame(minWidth: large ? 26 : 16, minHeight: large ? 24 : 17)
            .padding(.horizontal, label.count > 1 ? (large ? 7 : 4) : 0)
            .background(RoundedRectangle(cornerRadius: large ? 5 : 3.5, style: .continuous).fill(Color.wash))
            .overlay(RoundedRectangle(cornerRadius: large ? 5 : 3.5, style: .continuous).strokeBorder(Color.hairline))
    }
}

struct KeyCombo: View {
    let keys: [String]
    var large = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in Keycap(label: k, large: large) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: - Controls

/// A small monochrome switch. Filled ink when on, hairline when off.
struct InkSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""
    var body: some View {
        Button {
            withAnimation(Motion.micro) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.solidInk : Color.wash)
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.ink4, lineWidth: 1))
                Circle()
                    .fill(isOn ? Color.paper : Color.ink3)
                    .padding(isOn ? 2.5 : 3.5)
            }
            .frame(width: 30, height: 17)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Monochrome segmented control: hairline track, solid ink thumb that slides.
struct InkSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button {
                    withAnimation(Motion.micro) { selection = opt.0 }
                } label: {
                    Text(opt.1)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.paper : Color.ink2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(minWidth: 54)
                        .background {
                            if on { Capsule().fill(Color.solidInk).matchedGeometryEffect(id: "thumb", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.wash))
        .overlay(Capsule().strokeBorder(Color.hairline))
    }
}

/// Plain button that dips slightly while pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Secondary action: hairline capsule.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(Color.ink)
            .padding(.vertical, compact ? 4 : 7)
            .padding(.horizontal, compact ? 10 : 14)
            .background(Capsule().fill(configuration.isPressed ? Color.wash : Color.clear))
            .overlay(Capsule().strokeBorder(Color.ink4, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Primary action: solid ink capsule (white on dark, black on light).
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.paper)
            .padding(.vertical, 7).padding(.horizontal, 16)
            .background(Capsule().fill(Color.solidInk.opacity(configuration.isPressed ? 0.85 : 1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// ○ / ● status mark: hollow when something is missing, filled when it's working.
struct StatusDot: View {
    var on: Bool
    var body: some View {
        Circle()
            .strokeBorder(Color.ink, lineWidth: on ? 0 : 1.2)
            .background(Circle().fill(on ? Color.ink : .clear))
            .frame(width: 8, height: 8)
            .animation(Motion.micro, value: on)
            .accessibilityHidden(true)
    }
}

/// Tiny monochrome tag.
struct Tag: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.mono(9, weight: .medium)).tracking(0.6)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(Color.ink3)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.hairline))
    }
}

// MARK: - Charts

/// 14 days as a 1 px ink line with a 6 % wash, today marked with a dot.
struct DayLine: View {
    let days: [(Date, Int)]
    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let values = days.map { Double($0.1) }
                let maxV = max(1, values.max() ?? 1)
                guard values.count > 1 else { return }
                let step = size.width / CGFloat(values.count - 1)
                func pt(_ i: Int) -> CGPoint {
                    CGPoint(x: CGFloat(i) * step, y: size.height - 2 - CGFloat(values[i] / maxV) * (size.height - 6))
                }
                var line = Path()
                for i in values.indices { i == 0 ? line.move(to: pt(i)) : line.addLine(to: pt(i)) }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(.primary.opacity(0.06)))
                ctx.stroke(line, with: .color(.primary.opacity(0.85)), lineWidth: 1)
                let last = pt(values.count - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(.primary))
            }
            .frame(height: 56)
            HStack {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Text(d.0.formatted(.dateTime.weekday(.narrow))).font(.mono(9)).foregroundStyle(Color.ink4)
                    if i < days.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Entrance

/// The one-time entrance (onboarding steps, first appearances) — Emil Kowalski's Linear intro recipe:
/// a 4 px blur, a small Y move and a fade. Never used on surfaces that animate often (blur isn't free).
struct EntranceModifier: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active && !reduceMotion ? 0.96 : 1)
            .offset(y: active && !reduceMotion ? 6 : 0)
            .blur(radius: active && !reduceMotion ? 4 : 0)
    }
}

extension AnyTransition {
    static var entrance: AnyTransition {
        .modifier(active: EntranceModifier(active: true), identity: EntranceModifier(active: false))
    }
}
