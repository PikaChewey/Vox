import AppKit
import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings = Settings.shared
    var finish: () -> Void

    @State private var step: Int

    init(controller: DictationController, finish: @escaping () -> Void, initialStep: Int = 0) {
        self.controller = controller
        self.finish = finish
        _step = State(initialValue: initialStep)
    }
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var ax = HotkeyMonitor.accessibilityTrusted
    @State private var im = HotkeyMonitor.inputMonitoringGranted
    @State private var practice = ""
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: key
                default: tryIt
                }
            }
            .id(step)
            .transition(.entrance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 56).padding(.top, 44)

            HStack(spacing: 12) {
                Text(String(format: "%02d / %02d", step + 1, steps)).font(.mono(10)).foregroundStyle(Color.ink4)
                Spacer()
                if step > 0 { Button("Back") { go(step - 1) }.buttonStyle(OutlineButtonStyle(compact: true)) }
                Button(primaryLabel) {
                    if step == steps - 1 { finish() } else { go(step + 1) }
                }
                .buttonStyle(InkButtonStyle())
                .disabled(step == 1 && !(mic && ax))
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 680, height: 500)
        .background(Color.canvas)
        // Permission state only changes when the user acts in System Settings: re-check when we come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onAppear(perform: refresh)
    }

    private var primaryLabel: String {
        if step == steps - 1 { return "Start using Vox" }
        if step == 1 && !(mic && ax) { return "Waiting for access" }
        return "Continue"
    }

    private func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        ax = HotkeyMonitor.accessibilityTrusted
        im = HotkeyMonitor.inputMonitoringGranted
        if ax, !controller.hotkeysActive { controller.startHotkeys() }
    }

    private func go(_ s: Int) { withAnimation(Motion.smooth) { step = s } }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 26) {
            WelcomeIsland()
            VStack(spacing: 10) {
                Text("Talk. It types.").font(.system(size: 34, weight: .semibold)).tracking(-0.8)
                Text("Tap a key, speak naturally, and clean text lands wherever your cursor is.\nFree, unlimited, and entirely on this Mac.")
                    .font(.system(size: 13.5)).foregroundStyle(Color.ink3).multilineTextAlignment(.center)
            }
            HStack(alignment: .top, spacing: 0) {
                fact("ON-DEVICE", "Your voice never leaves your Mac.")
                Hairline(vertical: true).frame(height: 40)
                fact("LIVE", "Watch your words appear as you speak.")
                Hairline(vertical: true).frame(height: 40)
                fact("ANY APP", "Works wherever your cursor is.")
            }
            .frame(maxWidth: 540)
        }
    }

    private func fact(_ title: String, _ text: String) -> some View {
        VStack(spacing: 5) {
            Caption(title)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Color.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 10)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Three permissions", subtitle: "macOS asks for each once. Vox only listens while you're dictating.")
            InkGroup {
                permissionRow("Microphone", "Hears you only while you're dictating.", mic) {
                    Task { mic = await AudioRecorder.requestPermission() }
                }
                permissionRow("Accessibility", "Pastes at your cursor and reads which app you're in.", ax) {
                    HotkeyMonitor.promptAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                permissionRow("Input Monitoring", "Notices when you press the key.", im, last: true) {
                    HotkeyMonitor.promptInputMonitoring()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            }
            if ax && !im {
                Text("If the key doesn't respond after you allow Input Monitoring, quit and reopen Vox.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.ink3)
            }
        }
        .frame(maxWidth: 520)
    }

    private func permissionRow(_ title: String, _ detail: String, _ granted: Bool, last: Bool = false, action: @escaping () -> Void) -> some View {
        LabeledRow(title, detail: detail, last: last) {
            if granted {
                HStack(spacing: 6) { Text("Allowed").font(.system(size: 11.5)).foregroundStyle(Color.ink3); StatusDot(on: true) }
            } else {
                Button("Allow", action: action).buttonStyle(OutlineButtonStyle(compact: true))
            }
        }
        .animation(Motion.micro, value: granted)
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Your key", subtitle: "Tap it to talk, tap again to paste. Prefer holding? Turn on Hold to talk in Settings.")
            HStack(spacing: 10) {
                ForEach(TriggerKey.common) { k in
                    let on = settings.trigger == k
                    Button { withAnimation(Motion.micro) { settings.trigger = k } } label: {
                        VStack(spacing: 10) {
                            Keycap(label: k.keycap, large: true)
                            Text(k.label).font(.system(size: 11)).foregroundStyle(on ? Color.ink : Color.ink3)
                        }
                        .frame(width: 118, height: 86)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.wash : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.ink : Color.hairline, lineWidth: on ? 1.2 : 1))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            if settings.trigger == .fn {
                HStack(spacing: 10) {
                    Text("So fn doesn't open the emoji picker: Keyboard › “Press 🌐 key to” › Do Nothing.")
                        .font(.system(size: 12)).foregroundStyle(Color.ink2)
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
            }
            InkGroup {
                LabeledRow("Speech model", detail: controller.speechReady ? "Ready on the Neural Engine." : controller.statusLine) {
                    StatusDot(on: controller.speechReady)
                }
                LabeledRow("Cleanup model", detail: AppleLLM.isAvailable ? "Apple Intelligence"
                           : (LlamaServer.binaryPath() == nil ? "Run: brew install llama.cpp" : "Qwen3-4B via llama.cpp, downloads once."), last: true) {
                    StatusDot(on: AppleLLM.isAvailable || LlamaServer.binaryPath() != nil)
                }
            }
        }
        .frame(maxWidth: 540)
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Try it", subtitle: "Click the box, tap your key, say the line below, then tap it again. Watch the notch while you talk.")
            HStack(spacing: 10) {
                KeyCombo(keys: [settings.trigger.keycap], large: true)
                Text("“Um, so can you make the login button blue — no wait, green — and also add a hover state”")
                    .font(.system(size: 13)).italic().foregroundStyle(Color.ink2)
            }
            TextEditor(text: $practice)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(practice.isEmpty ? Color.hairline : Color.ink4))
            if !practice.isEmpty {
                HStack(spacing: 8) {
                    StatusDot(on: true)
                    Text("The ums, the false start and the correction are gone.").font(.system(size: 12)).foregroundStyle(Color.ink2)
                }
                .transition(.entrance)
            }
        }
        .frame(maxWidth: 540)
        .animation(Motion.snappy, value: practice.isEmpty)
    }
}
