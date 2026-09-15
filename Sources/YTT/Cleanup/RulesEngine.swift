import Foundation

// Stage one of cleanup: rules from a hand-editable JSON file.
// Lives in the data folder (see DataDir), which can point at a synced
// folder so every Mac shares it. Resources/rules.json seeds it when missing.
final class RulesEngine {
    struct Entry: Decodable {
        let to: String
        let from: [String]?
    }
    struct File: Decodable {
        let rules: [String: Bool]
        let dictionary: [Entry]
    }

    static var runtimePath: String { DataDir.url.appendingPathComponent("rules.json").path }

    private var file: File?
    private var loadedModified: Date?
    private var replacements: [(NSRegularExpression, String)] = []

    init() { seedIfMissing(); reloadIfChanged() }

    private func seedIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: RulesEngine.runtimePath),
              let seed = Bundle.main.url(forResource: "rules", withExtension: "json") else { return }
        try? fm.createDirectory(atPath: (RulesEngine.runtimePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.copyItem(at: seed, to: URL(fileURLWithPath: RulesEngine.runtimePath))
        Log.info("RULES seeded \(RulesEngine.runtimePath)")
    }

    // Cheap mtime check on every dictation, so edits apply without a restart.
    func reloadIfChanged() {
        let path = FileManager.default.fileExists(atPath: RulesEngine.runtimePath)
            ? RulesEngine.runtimePath
            : Bundle.main.path(forResource: "rules", ofType: "json") ?? ""
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard modified != loadedModified || file == nil else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let parsed = try JSONDecoder().decode(File.self, from: data)
            file = parsed
            loadedModified = modified
            replacements = parsed.dictionary.flatMap { entry -> [(NSRegularExpression, String)] in
                let wrong = (entry.from ?? []) + [entry.to]
                return wrong.compactMap { w in
                    let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])"
                    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
                    return (re, entry.to)
                }
            }
            Log.info("RULES loaded \(parsed.dictionary.count) dictionary entries, rules=\(parsed.rules.filter { $0.value }.keys.sorted())")
        } catch {
            Log.warn("RULES failed to load \(path): \(error.localizedDescription)")
        }
    }

    private func on(_ name: String) -> Bool { file?.rules[name] ?? false }

    // Correct spellings, for the engine's hotword list.
    var dictionaryTerms: [String] { file?.dictionary.map(\.to) ?? [] }
    var hotwordsEnabled: Bool { file?.rules["hotwords"] ?? true }
    // Off means one send after release, as before Phase 7. No relaunch needed.
    var chunkedDecodeEnabled: Bool { file?.rules["chunkedDecode"] ?? true }
    // Off means one paragraph, as before Phase 8.
    var paragraphsEnabled: Bool { file?.rules["paragraphs"] ?? true }

    // Word-level cleanup: dictionary fixes and currency spacing. Safe to run
    // per chunk, before the sentence is complete.
    func applyWords(_ input: String) -> String {
        reloadIfChanged()
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if on("dictionary") {
            for (re, to) in replacements {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: to))
            }
        }
        if on("spaceBeforeCurrency") {
            text = text.replacingOccurrences(of: "(?<=[\\p{L}\\p{N}])(?=[$€£])", with: " ", options: .regularExpression)
        }
        return text
    }

    // Sentence-level cleanup: capitalization and terminal punctuation. Only
    // meaningful once a piece of text is a whole sentence.
    func applySentence(_ input: String) -> String {
        reloadIfChanged()
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if on("capitalizeFirst"), let first = text.first, first.isLetter, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if on("terminalPunctuation"), let last = text.last, !".?!:;,".contains(last) {
            text += (on("questionMark") && RulesEngine.looksLikeQuestion(text)) ? "?" : "."
        }
        return text
    }

    // CleanupPipeline and --clean still use the combined pass.
    func apply(_ input: String) -> String { applySentence(applyWords(input)) }

    // Auxiliary verbs (is, are, can, should, ...) used to be in this set, but
    // they fire on plain statements too ("Is what I said") and on paragraphs
    // whose first sentence was a question but whose last sentence was not
    // ("Because I don't know how relevant these are" got a "?" because the
    // paragraph opened with "Is this..."). Only the true question words are
    // reliable enough to add a "?" on their own.
    private static let questionWords: Set<String> = [
        "what", "who", "whom", "whose", "where", "when", "why", "how", "which",
    ]

    static func looksLikeQuestion(_ text: String) -> Bool {
        let last = lastSentence(text)
        guard let firstWord = last.split(whereSeparator: { !$0.isLetter }).first else { return false }
        return questionWords.contains(firstWord.lowercased())
    }

    // Splits off the final sentence so the question-mark decision only looks
    // at what the text is actually ending on, not an earlier sentence in the
    // same paragraph. Same conservative split Seam.sentenceCount uses: a
    // `.`, `?`, or `!` counts only when it ends a word (followed by
    // whitespace or end of string) and is preceded by a letter or digit; a
    // single capital letter before a `.` (an initial, e.g. "J.") does not
    // count as a split point.
    private static func lastSentence(_ text: String) -> String {
        let chars = Array(text)
        var splitAt: Int?
        for i in chars.indices {
            let c = chars[i]
            guard c == "." || c == "?" || c == "!" else { continue }
            let endsWord = (i + 1 == chars.count) || chars[i + 1].isWhitespace
            guard endsWord, i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber else { continue }
            if c == ".", chars[i - 1].isUppercase {
                let precededByLetterOrDigit = i > 1 && (chars[i - 2].isLetter || chars[i - 2].isNumber)
                if !precededByLetterOrDigit { continue }
            }
            splitAt = i + 1
        }
        guard let splitAt, splitAt < chars.count else { return text }
        return String(chars[splitAt...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
