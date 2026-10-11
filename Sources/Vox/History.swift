import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var app: String?
    var raw: String
    var final: String
    var audioSeconds: Double
    /// Key-up → text pasted.
    var latencyMs: Int
    var engine: String
    /// "dictate" or "command" (nil in v1 history = dictate).
    var mode: String? = nil
    var bundleID: String? = nil
}

/// Local-only history + Wispr-style stats (words dictated, WPM, streak, time saved). Stored as JSON in
/// ~/Library/Application Support/Vox — never leaves the Mac.
@MainActor
final class History: ObservableObject {
    static let shared = History()
    static let typingWPM = 40.0

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var totalWords = 0
    @Published private(set) var totalSessions = 0
    @Published private(set) var totalSpeakingSeconds = 0.0
    @Published private(set) var activeDays: Set<String> = []
    @Published private(set) var totalCleaned = 0

    private struct Store: Codable {
        var entries: [HistoryEntry]; var totalWords: Int; var totalSessions: Int
        var totalSpeakingSeconds: Double; var activeDays: Set<String>
        var totalCleaned: Int?
    }

    private let url = Paths.support.appendingPathComponent("history.json")
    private let maxEntries = 500

    private init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder.iso.decode(Store.self, from: d) {
            entries = s.entries; totalWords = s.totalWords; totalSessions = s.totalSessions
            totalSpeakingSeconds = s.totalSpeakingSeconds; activeDays = s.activeDays
            totalCleaned = s.totalCleaned ?? 0
        }
    }

    func add(_ e: HistoryEntry) {
        if Settings.shared.keepHistory {
            entries.insert(e, at: 0)
            if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        }
        let words = RuleCleaner.wordCount(e.final)
        totalWords += words
        totalCleaned += max(0, RuleCleaner.wordCount(e.raw) - words)
        totalSessions += 1
        totalSpeakingSeconds += e.audioSeconds
        activeDays.insert(Self.dayKey(e.date))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let s = Store(entries: entries, totalWords: totalWords, totalSessions: totalSessions,
                      totalSpeakingSeconds: totalSpeakingSeconds, activeDays: activeDays,
                      totalCleaned: totalCleaned)
        if let d = try? JSONEncoder.iso.encode(s) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Stats

    var wordsToday: Int {
        let k = Self.dayKey(Date())
        return entries.filter { Self.dayKey($0.date) == k }.reduce(0) { $0 + RuleCleaner.wordCount($1.final) }
    }

    var speakingWPM: Int {
        totalSpeakingSeconds > 5 ? Int(Double(totalWords) / (totalSpeakingSeconds / 60)) : 0
    }

    /// Minutes saved vs typing at 40 WPM.
    var minutesSaved: Int {
        max(0, Int(Double(totalWords) / Self.typingWPM - totalSpeakingSeconds / 60))
    }

    var streakDays: Int {
        var n = 0
        var d = Date()
        let cal = Calendar.current
        // Today counts if you've dictated; otherwise the streak can still be alive from yesterday.
        if !activeDays.contains(Self.dayKey(d)) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while activeDays.contains(Self.dayKey(d)) {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return n
    }

    /// Where you dictate most (from recent history).
    var topApps: [(String, Int)] {
        var c: [String: Int] = [:]
        for e in entries { c[e.app ?? "Other", default: 0] += RuleCleaner.wordCount(e.final) }
        return c.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    /// Words per day for the last 14 days (oldest first) — the little bar chart on Home.
    var last14Days: [(Date, Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var byDay: [String: Int] = [:]
        for e in entries { byDay[Self.dayKey(e.date), default: 0] += RuleCleaner.wordCount(e.final) }
        return (0..<14).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            return (d, byDay[Self.dayKey(d)] ?? 0)
        }
    }

    var medianLatencyMs: Int {
        let l = entries.prefix(50).map(\.latencyMs).sorted()
        return l.isEmpty ? 0 : l[l.count / 2]
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}


/// Word-level diff of what the cleanup changed (computed only when a row's "Changes" is opened).
enum WordDiff {
    enum Kind { case same, removed, added }

    static func compute(_ raw: String, _ final: String) -> [(String, Kind)]? {
        let a = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = final.split(whereSeparator: \.isWhitespace).map(String.init)
        guard a.count * b.count <= 400_000 else { return nil }     // ~630 × 630 words; longer → plain original
        func key(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let ka = a.map(key), kb = b.map(key)
        // LCS table, bottom-up.
        var t = [[UInt16]](repeating: [UInt16](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = ka[i] == kb[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [(String, Kind)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j] { out.append((b[j], .same)); i += 1; j += 1 }
            else if j < b.count, i == a.count || t[i][j + 1] >= t[i + 1][j] { out.append((b[j], .added)); j += 1 }
            else { out.append((a[i], .removed)); i += 1 }
        }
        return out
    }
}
