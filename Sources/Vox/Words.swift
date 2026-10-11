import AppKit

/// "Is this a real English word?" for the cleanup heuristics (sentence joins, capitalisation, name detection).
/// Word checks go to macOS's spell checker: its dictionary lives in the system spell service, so Vox
/// doesn't hold an ~8 MB word list (≈0.08 ms per lookup, cached).
enum Words {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    private static func spelledCorrectly(_ w: String) -> Bool {
        lock.lock()
        if let hit = cache[w] { lock.unlock(); return hit }
        lock.unlock()
        let ok = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                     inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        lock.lock()
        if cache.count > 4_000 { cache.removeAll(keepingCapacity: true) }
        cache[w] = ok
        lock.unlock()
        return ok
    }

    /// A real lowercase English word (names like "priya" or "mccall" are not).
    static func isReal(_ w: String) -> Bool {
        let w = w.lowercased()
        guard w.contains(where: \.isLetter) else { return false }
        return spelledCorrectly(w)
    }

    /// Only correct when capitalised ("alzheimer's" → "Alzheimer's", "paris" → "Paris").
    static func isProperNoun(_ w: String) -> Bool {
        let lower = w.lowercased()
        guard lower.count > 1, !spelledCorrectly(lower) else { return false }
        return spelledCorrectly(lower.prefix(1).uppercased() + lower.dropFirst())
    }
}
