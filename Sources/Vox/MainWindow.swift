import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case home, history, styles, dictionary, snippets, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .styles: "Styles"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: "waveform"
        case .history: "clock"
        case .styles: "textformat"
        case .dictionary: "character.book.closed"
        case .snippets: "text.insert"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published var section: Section = .home
}

struct MainWindow: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var nav: Navigator

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                ForEach([Section.home, .history]) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                SwiftUI.Section("Writing") {
                    ForEach([Section.styles, .dictionary, .snippets]) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                }
                SwiftUI.Section("App") {
                    Label(Section.settings.title, systemImage: Section.settings.symbol).tag(Section.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarFooter(controller: controller).padding(12) }
        } detail: {
            ScrollView {
                page
                    .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(nav.section)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.12), value: nav.section)
            .background(Color.canvas)
            .navigationTitle(nav.section.title)
        }
        .frame(minWidth: 800, minHeight: 540)
    }

    @ViewBuilder private var page: some View {
        switch nav.section {
        case .home: HomePage(controller: controller, history: History.shared)
        case .history: HistoryPage(history: History.shared)
        case .styles: StylesPage(settings: Settings.shared)
        case .dictionary: DictionaryPage(settings: Settings.shared, controller: controller)
        case .snippets: SnippetsPage(settings: Settings.shared)
        case .settings: SettingsPage(controller: controller, settings: Settings.shared)
        }
    }
}

private struct SidebarFooter: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(on: controller.speechReady)
            Text(controller.speechReady ? "On this Mac" : controller.statusLine)
                .font(.mono(10)).foregroundStyle(Color.ink3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var history: History
    @ObservedObject var settings = Settings.shared
    @State private var shared = false

    /// What each key does, from the current settings (recorded shortcuts included).
    private var keyRows: [([String], String)] {
        let k = settings.trigger.keycap
        var rows: [([String], String)] = settings.holdToTalk
            ? [([k], "Hold, talk, let go. Words appear in the notch as you speak."),
               ([k, k], "Double-tap for hands-free. Tap again to finish.")]
            : [([k], "Tap, talk, tap again to finish. Words appear in the notch as you speak.")]
        rows.append(([k, "⇧"], "Command: rewrite the selected text by voice."))
        let texts: [ShortcutAction: String] = [.pasteLast: "Paste your last dictation again.",
                                               .pasteOriginal: "Paste your last dictation without the AI edits.",
                                               .cancel: "Cancel while dictating."]
        for a in ShortcutAction.allCases {
            if let sc = settings.shortcuts[a] { rows.append((sc.keys, texts[a] ?? a.title)) }
        }
        return rows
    }

    var body: some View {
        // Each of these scans the history: compute once per render.
        let apps = history.topApps
        let days = history.last14Days
        let today = history.wordsToday
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                PageHeader(title: "Vox", subtitle: "Speak messy, send clean. Everything stays on this Mac.")
                Button(shared ? "Copied" : "Share stats") {
                    ShareCard.copyToClipboard(history: history)
                    withAnimation(Motion.micro) { shared = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(Motion.micro) { shared = false } }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            }

            InkGroup {
                HStack(spacing: 0) {
                    Readout(caption: "Words", value: history.totalWords.formatted())
                    Hairline(vertical: true).frame(height: 44).padding(.horizontal, 14)
                    Readout(caption: "Pace", value: "\(history.speakingWPM)", unit: "wpm")
                    Hairline(vertical: true).frame(height: 44).padding(.horizontal, 14)
                    Readout(caption: "Streak", value: "\(history.streakDays)", unit: history.streakDays == 1 ? "day" : "days")
                    Hairline(vertical: true).frame(height: 44).padding(.horizontal, 14)
                    Readout(caption: "Saved", value: "\(history.minutesSaved)", unit: "min")
                }
                .padding(.vertical, 8)
            }

            InkGroup("Last 14 days", trailing: AnyView(Text("\(today.formatted()) today").font(.mono(10)).foregroundStyle(Color.ink3))) {
                DayLine(days: days).padding(.vertical, 10)
            }

            InkGroup("Keys") {
                let rows = keyRows
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    KeyRow(keys: r.0, text: r.1, last: i == rows.count - 1)
                }
            }

            if !apps.isEmpty {
                InkGroup("Where you talk") {
                    ForEach(Array(apps.enumerated()), id: \.offset) { i, item in
                        HStack {
                            Text(item.0).font(.system(size: 12.5))
                            Spacer()
                            Text(item.1.formatted()).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.ink3)
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { if i < apps.count - 1 { Hairline().opacity(0.6) } }
                    }
                }
            }

            if !history.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Recent")
                    ForEach(history.entries.prefix(3)) { HistoryRow(entry: $0) }
                }
            }
        }
    }
}

private struct KeyRow: View {
    let keys: [String]
    let text: String
    var last = false
    var body: some View {
        HStack(spacing: 14) {
            KeyCombo(keys: keys).frame(width: 150, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Color.ink2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { if !last { Hairline().opacity(0.6) } }
    }
}

// MARK: - History

struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showRaw: Bool

    init(entry: HistoryEntry, showRaw: Bool = false) {
        self.entry = entry
        _showRaw = State(initialValue: showRaw)
    }
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute()).font(.mono(10)).foregroundStyle(Color.ink4)
                if let app = entry.app { Text(app).font(.system(size: 11)).foregroundStyle(Color.ink3) }
                if entry.mode == "command" { Tag(text: "command") }
                Spacer()
                HStack(spacing: 10) {
                    if entry.raw != entry.final {
                        Button(showRaw ? "Hide changes" : "Changes") { withAnimation(Motion.snappy) { showRaw.toggle() } }
                    }
                    Button("Copy") { copy(entry.final) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.ink3)
                .opacity(hover ? 1 : 0)
            }
            Text(entry.final).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if showRaw {
                Text(Self.changes(entry)).font(.system(size: 12)).foregroundStyle(Color.ink3).textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.hairline).frame(width: 1) }
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Color.wash : Color.clear))
        .onHover { hover = $0 }
    }

    /// What the cleanup did: removed words struck through, added words in full ink, the rest quiet.
    static func changes(_ e: HistoryEntry) -> AttributedString {
        guard let diff = WordDiff.compute(e.raw, e.final) else { return AttributedString(e.raw) }
        var out = AttributedString()
        for (n, (word, kind)) in diff.enumerated() {
            if n > 0 { out += AttributedString(" ") }     // spaces stay unstyled, so strikes don't run together
            var w = AttributedString(word)
            switch kind {
            case .same: break
            case .removed:
                w.strikethroughStyle = .single
                w.foregroundColor = Color.ink4
            case .added:
                w.foregroundColor = Color.ink
            }
            out += w
        }
        return out
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct HistoryPage: View {
    @ObservedObject var history: History
    @ObservedObject var settings = Settings.shared
    @State private var query = ""

    private var grouped: [(String, [HistoryEntry])] {
        let q = query.lowercased()
        let filtered = q.isEmpty ? history.entries : history.entries.filter {
            $0.final.lowercased().contains(q) || $0.raw.lowercased().contains(q) || ($0.app ?? "").lowercased().contains(q)
        }
        var out: [(String, [HistoryEntry])] = []
        for e in filtered {
            let k = e.date.formatted(Date.FormatStyle().weekday(.wide).month().day())
            if out.last?.0 == k { out[out.count - 1].1.append(e) } else { out.append((k, [e])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(title: "History", subtitle: "Every dictation, with what you actually said. Stored only on this Mac.")
                HStack(spacing: 8) {
                    Text("Keep").font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                    InkSwitch(isOn: $settings.keepHistory)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.ink4)
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline))

            if grouped.isEmpty {
                Text(query.isEmpty ? "Nothing yet. \(settings.holdToTalk ? "Hold" : "Tap") \(settings.trigger.label) in any app and start talking." : "No matches.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.ink3)
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(grouped, id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 2) {
                    Caption(day).padding(.bottom, 4)
                    ForEach(items) { HistoryRow(entry: $0) }
                }
            }
            if !history.entries.isEmpty {
                Button("Clear history") { history.clear() }.buttonStyle(OutlineButtonStyle(compact: true))
            }
        }
    }
}

// MARK: - Styles

struct StylesPage: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Styles", subtitle: "Vox notices the app you're in and writes the way you would there.")
            ForEach(StyleGroup.allCases) { g in
                InkGroup(g.label) {
                    LabeledRow("Cleanup", detail: (settings.styles[g]?.cleanup ?? .llm).detail) {
                        InkSegmented(selection: binding(g, \.cleanup), options: CleanupMode.allCases.map { ($0, $0.label) })
                    }
                    LabeledRow("Tone", detail: (settings.styles[g]?.tone ?? .formal).sample, last: true) {
                        InkSegmented(selection: binding(g, \.tone), options: Tone.allCases.map { ($0, $0.label) })
                    }
                }
            }
            InkGroup("Your own rules") {
                TextField("“British spelling”, “never use em dashes”, “I'm a Waterloo CS student”…", text: $settings.extraInstructions, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5).font(.system(size: 12.5)).padding(.vertical, 8)
            }
        }
    }

    private func binding<T>(_ g: StyleGroup, _ kp: WritableKeyPath<StylePreset, T>) -> Binding<T> {
        Binding(get: { (settings.styles[g] ?? Settings.defaultStyles[g]!)[keyPath: kp] },
                set: { v in var p = settings.styles[g] ?? Settings.defaultStyles[g]!; p[keyPath: kp] = v; settings.styles[g] = p })
    }
}

// MARK: - Dictionary & snippets

struct DictionaryPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: DictationController
    @State private var term = ""
    @State private var sounds = ""
    /// Shown under the add row, e.g. "Updated “Codex”".
    @State private var note: String?
    @State private var editing: UUID?
    @State private var editTerm = ""
    @State private var editSounds = ""
    @FocusState private var focus: Field?
    private enum Field: Hashable { case term, sounds }

    init(settings: Settings, controller: DictationController, editing: DictionaryTerm? = nil, note: String? = nil) {
        self.settings = settings
        self.controller = controller
        // `editing` is for --render-ui: shows a row open for editing.
        _editing = State(initialValue: editing?.id)
        _editTerm = State(initialValue: editing?.term ?? "")
        _editSounds = State(initialValue: editing?.soundsLike ?? "")
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Dictionary", subtitle: "Names and jargon spelled your way. Fix a word right after it's pasted and Vox learns it. Click a word to edit it.")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Word", text: $term).textFieldStyle(.roundedBorder).frame(width: 180)
                    TextField("Often heard as (optional)", text: $sounds).textFieldStyle(.roundedBorder)
                    Button("Add") { add() }.keyboardShortcut(.defaultAction).buttonStyle(InkButtonStyle())
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Color.ink3).transition(.opacity) }
            }
            InkGroup("\(settings.dictionary.count) words") {
                ForEach(Array(settings.dictionary.enumerated()), id: \.element.id) { i, t in
                    Group {
                        if editing == t.id { editRow(t) } else { row(t) }
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { if i < settings.dictionary.count - 1 { Hairline().opacity(0.6) } }
                }
            }
            InkGroup {
                LabeledRow("Learn from my corrections", detail: "Watches only the field it just typed into, for a few seconds.") {
                    InkSwitch(isOn: $settings.learnCorrections)
                }
                LabeledRow("Boost words in the speech model", detail: "Experimental. Can over-correct ordinary words.", last: true) {
                    InkSwitch(isOn: $settings.vocabularyBoosting)
                }
            }
            .onChange(of: settings.vocabularyBoosting) { refresh() }
        }
        .onDisappear { saveEdit(); refresh() }
    }

    private func row(_ t: DictionaryTerm) -> some View {
        HStack(spacing: 10) {
            Button { startEdit(t, focusing: .sounds) } label: {
                HStack(spacing: 10) {
                    Text(t.term).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink).frame(width: 170, alignment: .leading)
                    Text(t.soundsLike.isEmpty ? "—" : t.soundsLike).font(.system(size: 12)).foregroundStyle(Color.ink3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Edit")
            if t.learned { Tag(text: "learned") }
            Button { startEdit(t, focusing: .sounds) } label: {
                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink4)
            }.buttonStyle(.plain).help("Edit").accessibilityLabel("Edit \(t.term)")
            Button { settings.dictionary.removeAll { $0.id == t.id }; refresh() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.ink4)
            }.buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(t.term)")
        }
    }

    private func editRow(_ t: DictionaryTerm) -> some View {
        HStack(spacing: 8) {
            TextField("Word", text: $editTerm).textFieldStyle(.roundedBorder).frame(width: 170)
                .focused($focus, equals: .term)
            TextField("Often heard as, separated by commas", text: $editSounds).textFieldStyle(.roundedBorder)
                .focused($focus, equals: .sounds)
            Button("Save") { saveEdit() }.buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(editTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { editing = nil }.buttonStyle(OutlineButtonStyle(compact: true))
        }
        .onSubmit { saveEdit() }
        .onExitCommand { editing = nil }
    }

    private func startEdit(_ t: DictionaryTerm, focusing f: Field) {
        saveEdit()
        editTerm = t.term
        editSounds = t.soundsLike
        editing = t.id
        DispatchQueue.main.async { focus = f }
    }

    private func saveEdit() {
        guard let id = editing else { return }
        editing = nil
        let t = editTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = settings.dictionary.firstIndex(where: { $0.id == id }) else { return }
        let sounds = DictionaryTerm.joined(DictionaryTerm.split(editSounds))
        // Renamed onto a word that's already listed: fold the two together.
        if let j = settings.dictionary.firstIndex(where: { $0.id != id && $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            settings.dictionary[j].soundsLike = DictionaryTerm.merged(settings.dictionary[j].soundsLike, sounds)
            settings.dictionary[j].learned = false
            settings.dictionary.remove(at: i)
        } else {
            let old = settings.dictionary[i]
            guard old.term != t || old.soundsLike != sounds else { return }
            settings.dictionary[i].term = t
            settings.dictionary[i].soundsLike = sounds
            settings.dictionary[i].learned = false      // yours now
        }
        refresh()
    }

    private func add() {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        saveEdit()
        if let i = settings.dictionary.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            // Already there: add the new spellings to it instead of making a duplicate.
            settings.dictionary[i].soundsLike = DictionaryTerm.merged(settings.dictionary[i].soundsLike, sounds)
            settings.dictionary[i].learned = false
            show("Updated “\(settings.dictionary[i].term)”, which was already in your dictionary.")
        } else {
            settings.dictionary.insert(DictionaryTerm(term: t, soundsLike: DictionaryTerm.joined(DictionaryTerm.split(sounds))), at: 0)
            note = nil
        }
        term = ""; sounds = ""
        refresh()
    }

    private func show(_ text: String) {
        withAnimation(Motion.micro) { note = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if note == text { withAnimation(Motion.micro) { note = nil } } }
    }

    private func refresh() { Task { await controller.transcriber.configureVocabulary(settings.dictionary) } }
}

struct SnippetsPage: View {
    @ObservedObject var settings: Settings
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Snippets", subtitle: "Say a short phrase, get the long version: “my calendar link”, “my address”, “sign off”.")
            VStack(alignment: .leading, spacing: 8) {
                TextField("When I say…", text: $trigger).textFieldStyle(.roundedBorder)
                TextField("…type this", text: $expansion, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                Button("Add snippet") {
                    guard !trigger.isEmpty, !expansion.isEmpty else { return }
                    settings.snippets.insert(Snippet(trigger: trigger, expansion: expansion), at: 0)
                    trigger = ""; expansion = ""
                }
                .buttonStyle(InkButtonStyle())
                .disabled(trigger.isEmpty || expansion.isEmpty)
            }
            if !settings.snippets.isEmpty {
                InkGroup {
                    ForEach(Array(settings.snippets.enumerated()), id: \.element.id) { i, s in
                        HStack(alignment: .top, spacing: 12) {
                            Text("“\(s.trigger)”").font(.system(size: 12.5, weight: .medium)).frame(width: 160, alignment: .leading)
                            Text(s.expansion).font(.system(size: 12)).foregroundStyle(Color.ink3).lineLimit(3)
                            Spacer()
                            Button { settings.snippets.removeAll { $0.id == s.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.ink4)
                            }.buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { if i < settings.snippets.count - 1 { Hairline().opacity(0.6) } }
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: Settings
    @State private var axOK = HotkeyMonitor.accessibilityTrusted
    @State private var imOK = HotkeyMonitor.inputMonitoringGranted
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var mics = AudioDevices.inputDevices()
    @State private var openAtLogin = LoginItem.isEnabled
    @ObservedObject private var recorder = KeyRecorder.shared

    private func problem(_ t: KeyRecorder.Target) -> String? {
        recorder.problem?.target == t ? recorder.problem?.text : nil
    }
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginError: String?

    private var openAtLoginBinding: Binding<Bool> {
        Binding(get: { openAtLogin }, set: { on in
            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
            refreshLoginItem()
        })
    }

    private var openAtLoginDetail: String {
        if let loginError { return "Couldn't change it: \(loginError)" }
        if loginNeedsApproval { return "Allow Vox in System Settings › General › Login Items." }
        return "Vox starts quietly in the menu bar when you log in."
    }

    private func refreshLoginItem() {
        openAtLogin = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Settings")

            InkGroup("General") {
                LabeledRow("Open at login", detail: openAtLoginDetail, last: true) {
                    if loginNeedsApproval {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    } else {
                        InkSwitch(isOn: openAtLoginBinding)
                    }
                }
            }

            InkGroup("Permissions") {
                LabeledRow("Microphone", detail: "Only while you're dictating.") { permission(micOK) { Task { micOK = await AudioRecorder.requestPermission() } } }
                LabeledRow("Accessibility", detail: "Pastes at your cursor and reads which app you're in.") {
                    permission(axOK) {
                        HotkeyMonitor.promptAccessibility()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                LabeledRow("Input Monitoring", detail: "Notices when you press the key.", last: true) {
                    permission(imOK) {
                        HotkeyMonitor.promptInputMonitoring()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
            }

            InkGroup("Shortcuts", trailing: AnyView(
                Button("Restore defaults") {
                    recorder.stop()
                    settings.shortcuts = ShortcutAction.defaults
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.ink3)
                .disabled(settings.shortcuts == ShortcutAction.defaults))) {
                LabeledRow("Dictation key", detail: problem(.trigger) ?? (settings.trigger == .fn
                           ? "Set Keyboard › “Press 🌐 key to” › Do Nothing. Click to record another key."
                           : "Click, then press fn or a left or right ⌘ ⌥ ⌃.")) {
                    KeyField(target: .trigger, keys: [settings.trigger.keycap])
                }
                LabeledRow("Hold to talk", detail: settings.holdToTalk
                           ? "Hold the key while you talk, let go to paste. Double-tap for hands-free."
                           : "Off: tap the key to start, tap again to finish. No need to hold it.") {
                    InkSwitch(isOn: $settings.holdToTalk)
                }
                LabeledRow("Command mode", detail: "The dictation key with ⇧. Rewrites the selection, or writes something new.") {
                    KeyCombo(keys: [settings.trigger.keycap, "⇧"]).frame(minWidth: 136)
                }
                ForEach(ShortcutAction.allCases) { a in
                    LabeledRow(a.title, detail: problem(.action(a)) ?? a.detail + " Click to record, ⌫ to clear.",
                               last: a == ShortcutAction.allCases.last) {
                        KeyField(target: .action(a), keys: settings.shortcuts[a]?.keys)
                    }
                }
            }

            InkGroup("Input") {
                LabeledRow("Microphone", detail: "Automatic skips Bluetooth headset mics, so AirPods keep their sound quality.") {
                    Picker("", selection: $settings.micUID) {
                        Text("Automatic").tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().frame(width: 190)
                }
                LabeledRow("Speech model", detail: settings.asrModel.detail + " Runs on the Neural Engine.") {
                    Picker("", selection: $settings.asrModel) {
                        ForEach(ASRModelChoice.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 190)
                        .onChange(of: settings.asrModel) { Task { await controller.loadModels() } }
                }
                LabeledRow("Live transcript", detail: "See your words in the notch while you speak.") { InkSwitch(isOn: $settings.liveCaption) }
                LabeledRow("Lower music while dictating", last: true) { InkSwitch(isOn: $settings.duckAudio) }
            }

            InkGroup("Cleanup · on this Mac") {
                LabeledRow("Engine", detail: AppleLLM.isAvailable ? "Apple Intelligence is available." : "Apple Intelligence is off on this Mac.") {
                    Picker("", selection: $settings.llmBackend) {
                        ForEach(LLMBackend.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 230)
                }
                LabeledRow("Model", detail: "Qwen3-4B (default). Lighter: unsloth/Qwen3-1.7B-GGUF:Q4_K_M") {
                    TextField("", text: $settings.llamaModel).textFieldStyle(.roundedBorder).frame(width: 270)
                }
                LabeledRow("Use what's on screen", detail: "App name and the text before your cursor, read locally.") { InkSwitch(isOn: $settings.useAppContext) }
                LabeledRow("Give up after", detail: "Then the instant cleanup is used for that piece.") {
                    Stepper(String(format: "%.1f s", settings.llmTimeoutSeconds), value: $settings.llmTimeoutSeconds, in: 1...15, step: 0.5)
                        .font(.system(size: 12).monospacedDigit())
                }
                LabeledRow("Free model memory after", detail: "Reloads in about 2 s.", last: true) {
                    Stepper(settings.llmIdleUnloadMinutes == 0 ? "never" : "\(settings.llmIdleUnloadMinutes) min",
                            value: $settings.llmIdleUnloadMinutes, in: 0...120, step: 5)
                        .font(.system(size: 12).monospacedDigit())
                }
            }

            InkGroup("Output") {
                LabeledRow("“Press enter” sends", detail: "End with “press enter” to submit. Handy in Claude Code and ChatGPT.") { InkSwitch(isOn: $settings.autoSend) }
                LabeledRow("Restore my clipboard after pasting") { InkSwitch(isOn: $settings.restoreClipboard) }
                LabeledRow("Sounds", last: true) { InkSwitch(isOn: $settings.playSounds) }
            }

            HStack {
                Button("Run setup again") { NotificationCenter.default.post(name: .voxShowOnboarding, object: nil) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                Spacer()
                Text("VOX 3.0 · FREE · LOCAL").font(.mono(9.5)).tracking(0.8).foregroundStyle(Color.ink4)
            }
        }
        .onAppear {
            mics = AudioDevices.inputDevices()
            axOK = HotkeyMonitor.accessibilityTrusted
            imOK = HotkeyMonitor.inputMonitoringGranted
            micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            refreshLoginItem()
        }
        // Coming back from System Settings: pick up a login item allowed or removed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginItem() }
    }

    @ViewBuilder private func permission(_ ok: Bool, action: @escaping () -> Void) -> some View {
        if ok { StatusDot(on: true) } else { Button("Allow", action: action).buttonStyle(OutlineButtonStyle(compact: true)) }
    }
}

extension Notification.Name {
    static let voxShowOnboarding = Notification.Name("voxShowOnboarding")
}

// MARK: - Share card

/// A 1200×630 stats card for X, rendered locally and put on the clipboard (and saved to the Desktop).
enum ShareCard {
    @MainActor
    static func copyToClipboard(history: History) {
        let view = ShareCardView(words: history.totalWords, wpm: history.speakingWPM, streak: history.streakDays,
                                 saved: history.minutesSaved)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("Vox stats.png")
            try? png.write(to: url)
        }
    }
}

struct ShareCardView: View {
    let words: Int, wpm: Int, streak: Int, saved: Int
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.035)
            // Faint instrument reticle.
            Canvas { ctx, size in
                var grid = Path()
                var y: CGFloat = 20
                while y < size.height { var x: CGFloat = 20; while x < size.width { grid.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)); x += 24 }; y += 24 }
                ctx.fill(grid, with: .color(.white.opacity(0.05)))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    VoxMark().frame(width: 34, height: 34)
                    Text("vox").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("ON-DEVICE DICTATION").font(.mono(15)).tracking(2).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Text("WORDS SPOKEN, NOT TYPED").font(.mono(17)).tracking(2).foregroundStyle(.white.opacity(0.45))
                Text(words.formatted()).font(.system(size: 168, weight: .semibold).monospacedDigit()).tracking(-5).foregroundStyle(.white)
                Spacer()
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.bottom, 26)
                HStack(spacing: 0) {
                    stat("\(wpm)", "WPM")
                    stat("\(streak)", "DAY STREAK")
                    stat("\(saved)", "MIN SAVED")
                }
            }
            .padding(64)
        }
        .frame(width: 1200, height: 630)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v).font(.system(size: 52, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            Text(l).font(.mono(15)).tracking(1.6).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Vox mark (same as the app icon): four voice bars that brighten toward a text caret — what you say becomes
/// text at your cursor. Drawn fitted to its frame.
struct VoxMark: View {
    var ink: Color = .white
    var body: some View {
        Canvas { ctx, size in
            // Icon units (1024 canvas), see Resources/AppIcon.icon.
            let heights: [CGFloat] = [0.20, 0.36, 0.54, 0.36].map { $0 * 1024 }
            let opacity: [Double] = [0.30, 0.44, 0.60, 0.74]
            let barW: CGFloat = 62, gap: CGFloat = 104, caretGap: CGFloat = 122, caretW: CGFloat = 40, caretH: CGFloat = 0.62 * 1024
            let width = 3 * gap + caretGap + caretW / 2 + barW / 2
            let k = min(size.width / width, size.height / caretH)
            let ox = (size.width - width * k) / 2, cy = size.height / 2
            func capsule(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: ox + (x - w / 2) * k, y: cy - h * k / 2, width: w * k, height: h * k), cornerRadius: w * k / 2)
            }
            let x0 = barW / 2
            for (i, h) in heights.enumerated() {
                ctx.fill(capsule(x0 + CGFloat(i) * gap, barW, h), with: .color(ink.opacity(opacity[i])))
            }
            ctx.fill(capsule(x0 + 3 * gap + caretGap, caretW, caretH), with: .color(ink))
        }
        .accessibilityHidden(true)
    }
}
