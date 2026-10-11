import Foundation

/// Instant, deterministic cleanup. Runs before the LLM (so the LLM sees less junk) and is the
/// fallback whenever the LLM is off, slow, or produces something suspicious.
enum RuleCleaner {
    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    // "um", "uh", "erm", "hmm", "uh-huh" style noises. "like" / "you know" are too risky for rules — the LLM handles those.
    private static let fillers = re(#"(?<![\w'])(?:u+m+|u+h+|e+r+m+|e+h+|h+m+|mm+|uh-?huh)(?![\w'])[,.]?\s*"#)
    // "the the", "I I" — immediate stutter repeats of short words.
    private static let stutter = re(#"\b(\w{1,12})(?:[\s,]+\1\b)+"#)
    private static let scratch = re(#"\b(?:scratch that|delete that|strike that)\b[.!?,]?\s*"#)

    private static let spoken: [(NSRegularExpression, String)] = [
        (re(#"\s*\bnew paragraph\b[.,]?\s*"#), "\n\n"),
        (re(#"\s*\bnew line\b[.,]?\s*"#), "\n"),
    ]

    static func clean(_ raw: String, snippets: [Snippet] = []) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        s = replace(fillers, in: s, with: "")
        s = applyScratchThat(s)
        s = replace(stutter, in: s, with: "$1")
        for (r, t) in spoken { s = replace(r, in: s, with: t) }
        s = expandSnippets(s, snippets)
        s = tidy(s)
        return s
    }

    /// "scratch that" deletes what came before it: the current clause if the user was mid-sentence,
    /// otherwise the whole previous sentence ("Send it to John. No, scratch that. Send it to Mike.").
    static func applyScratchThat(_ text: String) -> String {
        var s = text
        while let m = scratch.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) {
            var prefix = String(s[..<r.lowerBound])
            let suffix = String(s[r.upperBound...])
            let boundary = CharacterSet(charactersIn: ".!?\n")
            // Text since the last sentence boundary.
            let lastB = prefix.rangeOfCharacter(from: boundary, options: .backwards)
            let tail = lastB.map { String(prefix[$0.upperBound...]) } ?? prefix
            let tailWords = tail.split { !$0.isLetter }.map { $0.lowercased() }
            let trivial = tailWords.allSatisfy { ["no", "oh", "actually", "wait", "sorry", "okay", "ok"].contains($0) }
            if let b = lastB {
                let kept = String(prefix[..<b.upperBound])   // up to and including the boundary
                if trivial {
                    // Drop the previous full sentence as well.
                    let before = String(prefix[..<b.lowerBound])
                    let prevB = before.rangeOfCharacter(from: boundary, options: .backwards)
                    prefix = prevB.map { String(before[..<$0.upperBound]) } ?? ""
                } else {
                    prefix = kept
                }
            } else {
                prefix = ""
            }
            s = prefix.trimmingCharacters(in: .whitespaces) + (prefix.isEmpty ? "" : " ") + suffix
        }
        return s
    }

    /// Dictionary replacements: "super base" → "Supabase", including words learned from your corrections.
    static func applyDictionary(_ text: String, _ terms: [DictionaryTerm]) -> String {
        var s = text
        for t in terms {
            for alias in t.aliases where alias.count >= 3 && !CorrectionLearner.isCommon(alias) {
                let r = re(#"(?<![\w'])"# + NSRegularExpression.escapedPattern(for: alias) + #"(?![\w'])"#)
                s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: t.term))
            }
        }
        return s
    }

    /// Snippets fire when the user says the trigger phrase, e.g. "my email" -> "bryan@example.com".
    static func expandSnippets(_ text: String, _ snippets: [Snippet]) -> String {
        var s = text
        for sn in snippets where !sn.trigger.trimmingCharacters(in: .whitespaces).isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: sn.trigger.trimmingCharacters(in: .whitespaces))
            let r = re(#"\b"# + escaped + #"\b[.!?]?"#)
            s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: sn.expansion))
        }
        return s
    }

    /// Spacing/capitalization fixes that are always safe.
    static func tidy(_ text: String) -> String {
        var s = text
        s = replace(re(#"[ \t]+([,.!?;:])"#), in: s, with: "$1")       // no space before punctuation
        s = replace(re(#"([,;:])(?=[^\s\d])"#), in: s, with: "$1 ")      // space after commas
        s = replace(re(#",\s*([.!?])"#), in: s, with: "$1")             // ",." -> "."
        s = replace(re(#"^[\s,.;:]+"#), in: s, with: "")                // leading junk
        s = replace(re(#"[ \t]{2,}"#), in: s, with: " ")
        s = replace(re(#"[ \t]*\n[ \t]*"#), in: s, with: "\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capitalize first letter of the text and after sentence ends / line breaks.
        var out = ""
        // Only after a sentence end followed by whitespace, so "Navbar.tsx" and "v1.2" stay intact.
        var capNext = true
        var sawEnd = false
        for ch in s {
            if capNext, ch.isLetter { out.append(contentsOf: ch.uppercased()); capNext = false; sawEnd = false; continue }
            out.append(ch)
            if ch == "\n" { capNext = true; sawEnd = false }
            else if ".!?".contains(ch) { sawEnd = true }
            else if ch.isWhitespace { if sawEnd { capNext = true } }
            else { sawEnd = false; capNext = false }
        }
        return out
    }

    /// Casual drops the final period; very casual also lowercases sentence starts (but never "I", names or
    /// acronyms). Lists and multi-paragraph text are left alone.
    static func applyTone(_ text: String, _ tone: Tone, keep: [String]) -> String {
        guard tone != .formal, !text.contains("\n") else { return text }
        var s = text
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        guard tone == .veryCasual else { return s }
        let keepSet = Set(keep.map { $0.lowercased() })
        var out = ""
        var atStart = true
        var word = ""
        func flush() {
            if atStart, let f = word.first, f.isUppercase, word != "I", !word.hasPrefix("I'"),
               word.dropFirst().allSatisfy({ $0.isLowercase || !$0.isLetter }),   // not an acronym
               !keepSet.contains(word.lowercased()), Words.isReal(word) {
                word = word.prefix(1).lowercased() + word.dropFirst()
            }
            if !word.isEmpty { atStart = false }
            out += word; word = ""
        }
        for ch in s {
            if ch.isLetter || ch == "'" { word.append(ch); continue }
            flush()
            out.append(ch)
            if ".!?".contains(ch) { atStart = true }
        }
        flush()
        return out
    }

    static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
}

/// Sanity checks on LLM output. Small models occasionally answer the question, drop half the content,
/// or wrap things in quotes. If the output looks wrong we paste the rule-cleaned text instead.
enum OutputGuard {
    static func sanitize(_ out: String) -> String {
        var s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<transcript>", "</transcript>", "<think>", "</think>"] { s = s.replacingOccurrences(of: tag, with: "") }
        if let r = s.range(of: #"^(?:here(?:'s| is) (?:the )?(?:cleaned|corrected|formatted)[^:\n]*:\s*)"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            s = String(s.dropFirst().dropLast())
        }
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `cleaned` is a plausible cleanup of `source` rather than a rewrite/answer.
    static func looksValid(cleaned: String, source: String) -> Bool {
        let a = words(source), b = words(cleaned)
        guard !b.isEmpty else { return false }
        if a.count < 4 { return b.count <= a.count + 4 }
        let ratio = Double(b.count) / Double(a.count)
        if ratio < 0.4 || ratio > 1.6 { return false }
        // Most words the LLM output should have come from what was said.
        let src = Set(a)
        let overlap = Double(b.filter { src.contains($0) }.count) / Double(b.count)
        return overlap >= 0.55
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
