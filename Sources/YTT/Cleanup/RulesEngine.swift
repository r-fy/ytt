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

    func apply(_ input: String) -> String {
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
        if on("capitalizeFirst"), let first = text.first, first.isLetter, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if on("terminalPunctuation"), let last = text.last, !".?!:;,".contains(last) {
            text += (on("questionMark") && RulesEngine.looksLikeQuestion(text)) ? "?" : "."
        }
        return text
    }

    private static let questionStarters: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could",
        "should", "would", "will", "shall", "have", "has", "had", "may", "might",
    ]

    static func looksLikeQuestion(_ text: String) -> Bool {
        guard let firstWord = text.split(whereSeparator: { !$0.isLetter }).first else { return false }
        return questionStarters.contains(firstWord.lowercased())
    }
}
