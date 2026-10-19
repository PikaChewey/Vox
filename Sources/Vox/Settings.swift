import Foundation
import ServiceManagement
import SwiftUI

/// Which physical key acts as push-to-talk. All are modifier keys so they never type a character.
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }
    var keycap: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        }
    }
}

enum ASRModelChoice: String, CaseIterable, Identifiable, Codable {
    case v2, ultra, v3
    /// Phonon-2 was dropped: on this FluidAudio build it returned only the first word of a clip.
    static var allCases: [ASRModelChoice] { [.v2, .ultra, .v3] }
    init?(rawValue: String) {
        switch rawValue {
        case "v2": self = .v2
        case "ultra": self = .ultra
        case "v3": self = .v3
        case "phonon2": self = .v2
        default: return nil
        }
    }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .v2: return "Parakeet v2 · English"
        case .ultra: return "Parakeet Ultra · 25 languages"
        case .v3: return "Parakeet v3 · 25 languages"
        }
    }
    var detail: String {
        switch self {
        case .v2: return "Best for English, and the lightest: ~38% less CPU per phrase than Ultra."
        case .ultra: return "Most accurate multilingual model."
        case .v3: return "Multilingual baseline."
        }
    }
}

/// How dictated text gets polished after transcription.
enum CleanupMode: String, CaseIterable, Identifiable, Codable {
    case off, rules, llm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Raw"
        case .rules: return "Fast"
        case .llm: return "Smart"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Exactly what you said."
        case .rules: return "Instant. Drops ums, stutters and “scratch that”."
        case .llm: return "Local AI fixes grammar, corrections and lists."
        }
    }
}

/// Wispr/BetterWispr-style tone. Casual drops the final period, very casual also drops capitals.
enum Tone: String, CaseIterable, Identifiable, Codable {
    case formal, casual, veryCasual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }
    var sample: String {
        switch self {
        case .formal: return "Hey, are you around for dinner tonight? Let's do 7."
        case .casual: return "Hey, are you around for dinner tonight? Let's do 7"
        case .veryCasual: return "hey are you around for dinner tonight? let's do 7"
        }
    }
}

/// The five style groups shown in the Styles page. Each maps several app categories.
enum StyleGroup: String, CaseIterable, Identifiable, Codable {
    case ai, messages, email, notes, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ai: return "AI & coding"
        case .messages: return "Messages"
        case .email: return "Email"
        case .notes: return "Docs & notes"
        case .other: return "Everything else"
        }
    }
    var apps: String {
        switch self {
        case .ai: return "Claude, ChatGPT, Cursor, VS Code, Xcode, Terminal, Ghostty…"
        case .messages: return "Messages, Slack, Discord, WhatsApp, X…"
        case .email: return "Mail, Gmail, Outlook, Superhuman…"
        case .notes: return "Notes, Notion, Obsidian, Google Docs…"
        case .other: return "Every other app"
        }
    }
    var symbol: String {
        switch self {
        case .ai: return "sparkles"
        case .messages: return "bubble.left.and.bubble.right"
        case .email: return "envelope"
        case .notes: return "doc.text"
        case .other: return "square.grid.2x2"
        }
    }
    static func of(_ c: AppCategory) -> StyleGroup {
        switch c {
        case .aiChat, .codeEditor, .terminal: return .ai
        case .chat: return .messages
        case .email: return .email
        case .notes: return .notes
        case .other: return .other
        }
    }
}

enum LLMBackend: String, CaseIterable, Identifiable, Codable {
    case auto, apple, llama
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (Apple Intelligence if on, else llama.cpp)"
        case .apple: return "Apple Intelligence"
        case .llama: return "llama.cpp (local GGUF model)"
        }
    }
}

struct StylePreset: Codable, Hashable {
    var cleanup: CleanupMode
    var tone: Tone
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

struct DictionaryTerm: Codable, Identifiable, Hashable {
    var id = UUID()
    /// How it should be written, e.g. "Supabase".
    var term: String
    /// Comma-separated ways the ASR tends to mishear it, e.g. "super base, soup a base".
    var soundsLike: String = ""
    /// Added automatically after the user corrected a dictation.
    var learned: Bool = false

    var aliases: [String] {
        soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey { case id, term, soundsLike, learned }
    init(term: String, soundsLike: String = "", learned: Bool = false) {
        self.term = term; self.soundsLike = soundsLike; self.learned = learned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        term = try c.decode(String.self, forKey: .term)
        soundsLike = (try? c.decode(String.self, forKey: .soundsLike)) ?? ""
        learned = (try? c.decode(Bool.self, forKey: .learned)) ?? false
    }
}

/// All user preferences, persisted to UserDefaults.
final class Settings: ObservableObject, @unchecked Sendable {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // Input
    @Published var trigger: TriggerKey { didSet { save("trigger", trigger.rawValue) } }
    /// Off (default): tap the key to start, tap again to finish. On: hold while you talk, double-tap for hands-free.
    @Published var holdToTalk: Bool { didSet { save("holdToTalk", holdToTalk) } }
    /// CoreAudio UID of the preferred mic; empty = automatic (avoids Bluetooth headset mics).
    @Published var micUID: String { didSet { save("micUID", micUID) } }
    @Published var asrModel: ASRModelChoice { didSet { save("asrModel", asrModel.rawValue) } }
    @Published var vocabularyBoosting: Bool { didSet { save("vocabularyBoosting", vocabularyBoosting) } }
    @Published var liveCaption: Bool { didSet { save("liveCaption", liveCaption) } }

    // Cleanup
    @Published var styles: [StyleGroup: StylePreset] { didSet { saveJSON("styles", styles) } }
    @Published var llmBackend: LLMBackend { didSet { save("llmBackend", llmBackend.rawValue) } }
    /// Hugging Face GGUF repo (optionally with :quant) passed to `llama-server -hf`.
    @Published var llamaModel: String { didSet { save("llamaModel", llamaModel) } }
    @Published var llmIdleUnloadMinutes: Int { didSet { save("llmIdleUnloadMinutes", llmIdleUnloadMinutes) } }
    @Published var llmTimeoutSeconds: Double { didSet { save("llmTimeoutSeconds", llmTimeoutSeconds) } }
    @Published var useAppContext: Bool { didSet { save("useAppContext", useAppContext) } }
    @Published var extraInstructions: String { didSet { save("extraInstructions", extraInstructions) } }

    // Output
    @Published var restoreClipboard: Bool { didSet { save("restoreClipboard", restoreClipboard) } }
    @Published var autoSend: Bool { didSet { save("autoSend", autoSend) } }
    @Published var learnCorrections: Bool { didSet { save("learnCorrections", learnCorrections) } }
    @Published var duckAudio: Bool { didSet { save("duckAudio", duckAudio) } }
    @Published var playSounds: Bool { didSet { save("playSounds", playSounds) } }
    @Published var keepHistory: Bool { didSet { save("keepHistory", keepHistory) } }

    // Words
    @Published var dictionary: [DictionaryTerm] { didSet { saveJSON("dictionary", dictionary) } }
    @Published var snippets: [Snippet] { didSet { saveJSON("snippets", snippets) } }

    @Published var onboarded: Bool { didSet { save("onboarded", onboarded) } }

    static let defaultStyles: [StyleGroup: StylePreset] = [
        .ai: .init(cleanup: .llm, tone: .formal),
        .messages: .init(cleanup: .llm, tone: .casual),
        .email: .init(cleanup: .llm, tone: .formal),
        .notes: .init(cleanup: .llm, tone: .formal),
        .other: .init(cleanup: .llm, tone: .formal),
    ]

    private init() {
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .fn
        holdToTalk = d.object(forKey: "holdToTalk") as? Bool ?? false
        micUID = d.string(forKey: "micUID") ?? ""
        asrModel = ASRModelChoice(rawValue: d.string(forKey: "asrModel") ?? "") ?? .v2
        vocabularyBoosting = d.object(forKey: "vocabularyBoosting") as? Bool ?? false
        liveCaption = d.object(forKey: "liveCaption") as? Bool ?? true
        llmBackend = LLMBackend(rawValue: d.string(forKey: "llmBackend") ?? "") ?? .auto
        llamaModel = d.string(forKey: "llamaModel") ?? "unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M"
        llmIdleUnloadMinutes = d.object(forKey: "llmIdleUnloadMinutes") as? Int ?? 10
        llmTimeoutSeconds = d.object(forKey: "llmTimeoutSeconds") as? Double ?? 4
        useAppContext = d.object(forKey: "useAppContext") as? Bool ?? true
        extraInstructions = d.string(forKey: "extraInstructions") ?? ""
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        autoSend = d.object(forKey: "autoSend") as? Bool ?? true
        learnCorrections = d.object(forKey: "learnCorrections") as? Bool ?? true
        duckAudio = d.object(forKey: "duckAudio") as? Bool ?? true
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        onboarded = d.object(forKey: "onboarded") as? Bool ?? false
        dictionary = Self.loadJSON(d, "dictionary") ?? Self.defaultDictionary
        snippets = Self.loadJSON(d, "snippets") ?? []
        var st: [StyleGroup: StylePreset] = Self.loadJSON(d, "styles") ?? Self.defaultStyles
        // v1 had a single global cleanup mode; carry it over.
        if d.object(forKey: "styles") == nil, let old = d.string(forKey: "cleanup"), let m = CleanupMode(rawValue: old) {
            for k in st.keys { st[k]?.cleanup = m }
        }
        for g in StyleGroup.allCases where st[g] == nil { st[g] = Self.defaultStyles[g] }
        styles = st
    }

    func style(for c: AppCategory) -> StylePreset {
        styles[StyleGroup.of(c)] ?? .init(cleanup: .llm, tone: .formal)
    }

    /// True if any style uses the LLM (decides whether to keep llama-server warm).
    var anyLLM: Bool { styles.values.contains { $0.cleanup == .llm } }

    /// Adds a word the user taught Vox by correcting a dictation.
    func learn(term: String, heard: String) {
        guard !dictionary.contains(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        dictionary.append(DictionaryTerm(term: term, soundsLike: heard.lowercased() == term.lowercased() ? "" : heard, learned: true))
    }

    static let defaultDictionary: [DictionaryTerm] = [
        .init(term: "Claude Code", soundsLike: "cloud code, clawed code"),
        .init(term: "Codex"),
        .init(term: "Cursor"),
        .init(term: "GitHub", soundsLike: "git hub"),
        .init(term: "TypeScript"),
        .init(term: "Next.js", soundsLike: "next js, next jay ess"),
        .init(term: "Supabase", soundsLike: "super base, soupabase"),
        .init(term: "Vercel", soundsLike: "versel,ver cell"),
        .init(term: "Tailwind"),
        .init(term: "SwiftUI", soundsLike: "swift ui, swift you eye"),
        .init(term: "localhost", soundsLike: "local host"),
        .init(term: "README", soundsLike: "read me"),
        .init(term: "JSON", soundsLike: "jason"),
        .init(term: "API"),
        .init(term: "CLI"),
        .init(term: "npm"),
    ]

    private func save(_ key: String, _ value: Any) { d.set(value, forKey: key) }
    private func saveJSON<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }
    private static func loadJSON<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Open at login, via the system's own login-item list (System Settings › General › Login Items). The system is
/// the source of truth, so turning it off there shows up here too; nothing is stored in UserDefaults.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    /// On but waiting for the user to allow it in System Settings.
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
