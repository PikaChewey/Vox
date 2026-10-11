import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ChatMessage: Codable { let role: String; let content: String }

protocol TextLLM: Sendable {
    var name: String { get }
    /// Called when recording starts so the model + system prompt are hot by the time the user stops talking.
    func prewarm(system: String, examples: [(String, String)]) async
    func complete(system: String, examples: [(String, String)], user: String, maxTokens: Int) async throws -> String
}

enum LLMError: LocalizedError {
    case unavailable(String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .badResponse(let s): return "LLM error: \(s)"
        }
    }
}

// MARK: - llama.cpp (llama-server, OpenAI-compatible, Metal)

/// Owns a private `llama-server` child process. llama.cpp downloads the GGUF from Hugging Face on first run
/// (free, cached in ~/Library/Caches/llama.cpp) and sleeps the model after idling to give RAM back.
actor LlamaServer: TextLLM {
    nonisolated let name = "llama.cpp"
    static let port = Int(ProcessInfo.processInfo.environment["VOX_LLAMA_PORT"] ?? "") ?? 51789
    private var process: Process?
    private var startedModel: String?
    private var adopted = false
    private var starting: Task<Void, Error>?
    private let base = URL(string: "http://127.0.0.1:\(LlamaServer.port)")!
    var status: String = "not started"

    static func binaryPath() -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("llama-server").path,
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func ensureRunning() async throws {
        let model = Settings.shared.llamaModel
        if (process?.isRunning == true || adopted), startedModel == Self.alias(model), await healthy() { return }
        // A cancelled caller's failed probe is not proof the server is dead: never stop/relaunch on its behalf.
        try Task.checkCancellation()
        if let t = starting { try await t.value; return }
        let t = Task { try await self.launch(model: model) }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    /// Identity of a running server: model + idle-unload setting (changing either restarts it on next use).
    private static func alias(_ model: String) -> String {
        "vox3:" + model.replacingOccurrences(of: " ", with: "") + ":idle\(Settings.shared.llmIdleUnloadMinutes)"
    }

    private func launch(model: String) async throws {
        stop()
        if await healthy() {
            // A server left over from a previous run (e.g. after a crash) is reused if it serves the same model;
            // otherwise it's ours but stale — replace it, or the new one can't bind the port.
            if await servedAlias() == Self.alias(model) { startedModel = Self.alias(model); adopted = true; status = "ready"; return }
            killStrays()
            for _ in 0..<20 where await healthy() { try await Task.sleep(nanoseconds: 150_000_000) }
        }
        guard let bin = Self.binaryPath() else {
            status = "llama-server not found"
            throw LLMError.unavailable("llama.cpp isn't installed. Run: brew install llama.cpp")
        }
        let idle = Settings.shared.llmIdleUnloadMinutes
        var args = ["-hf", model, "--host", "127.0.0.1", "--port", "\(Self.port)",
                    "-c", "2048", "-ctk", "q8_0", "-ctv", "q8_0", "-np", "1", "-ngl", "99", "-fa", "on", "--no-ui",
                    "--cache-reuse", "256", "--reasoning-budget", "0", "-a", Self.alias(model)]
        if idle > 0 { args += ["--sleep-idle-seconds", "\(idle * 60)"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let log = Paths.support.appendingPathComponent("llama-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        try p.run()
        process = p
        startedModel = Self.alias(model)
        status = "loading \(model)…"
        // First launch downloads the model (~2.5 GB) so allow a long wait; later launches take ~1–2 s.
        let deadline = Date().addingTimeInterval(60 * 20)
        while Date() < deadline {
            if !p.isRunning { status = "llama-server exited"; throw LLMError.unavailable("llama-server exited — see \(log.path)") }
            if await healthy() { status = "ready"; return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw LLMError.unavailable("llama-server took too long to start")
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        if adopted { killStrays(); adopted = false }
        process = nil
        status = "stopped"
    }

    /// Only ever targets llama-server instances on Vox's private port.
    private func killStrays() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "llama-server.*--port \(Self.port)"]
        try? k.run()
        k.waitUntilExit()
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func servedAlias() async -> String? {
        struct M: Decodable { struct D: Decodable { let id: String }; let data: [D]? }
        guard let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("v1/models")),
              let m = try? JSONDecoder().decode(M.self, from: data) else { return nil }
        return m.data?.first?.id
    }

    private func messages(_ system: String, _ examples: [(String, String)], _ user: String?) -> [ChatMessage] {
        var m = [ChatMessage(role: "system", content: system)]
        for (u, a) in examples {
            m.append(.init(role: "user", content: Prompts.wrapTranscript(u)))
            m.append(.init(role: "assistant", content: a))
        }
        if let user { m.append(.init(role: "user", content: user)) }
        return m
    }

    func prewarm(system: String, examples: [(String, String)]) async {
        guard (try? await ensureRunning()) != nil else { return }
        // Process the shared prefix now; llama-server keeps it in the KV cache for the real request.
        _ = try? await post(messages(system, examples, Prompts.wrapTranscript("ok")), maxTokens: 1, timeout: 30)
    }

    func complete(system: String, examples: [(String, String)], user: String, maxTokens: Int) async throws -> String {
        try await ensureRunning()
        return try await post(messages(system, examples, user), maxTokens: maxTokens, timeout: 60)
    }

    private func post(_ msgs: [ChatMessage], maxTokens: Int, timeout: TimeInterval) async throws -> String {
        struct Body: Encodable {
            let messages: [ChatMessage]; let temperature: Double; let top_p: Double
            let max_tokens: Int; let stream: Bool; let cache_prompt: Bool
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(messages: msgs, temperature: 0, top_p: 1,
                                                     max_tokens: maxTokens, stream: false, cache_prompt: true))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        struct R: Decodable { struct C: Decodable { struct M: Decodable { let content: String? }; let message: M }; let choices: [C] }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.choices.first?.message.content ?? ""
    }
}

// MARK: - Apple Intelligence on-device model (free, no download, needs Apple Intelligence turned on)

struct AppleLLM: TextLLM {
    let name = "Apple Intelligence"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let r): return "\(r)"
            }
        }
        #endif
        return "requires macOS 26"
    }

    func prewarm(system: String, examples: [(String, String)]) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Self.isAvailable {
            LanguageModelSession(instructions: system).prewarm()
        }
        #endif
    }

    func complete(system: String, examples: [(String, String)], user: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Self.isAvailable {
            var instructions = system
            if !examples.isEmpty {
                instructions += "\n\nExamples:"
                for (u, a) in examples { instructions += "\nInput: \(u)\nOutput: \(a)" }
            }
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                               instructions: instructions)
            let opts = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: maxTokens)
            return try await session.respond(to: user, options: opts).content
        }
        #endif
        throw LLMError.unavailable("Apple Intelligence is not available (\(Self.unavailableReason))")
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vox", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}
