import Foundation

// Files the speech server needs for hotword biasing. Both are derived, so
// they are regenerated at every launch.
//
// bpe.vocab: sherpa wants a sentencepiece-style "piece<TAB>score" list to
// split hotwords into model tokens. The model ships only tokens.txt
// ("piece id"). Using -id as the score (earlier ids are commoner pieces)
// worked in the Phase 6 test.
enum Hotwords {
    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/YTT")

    static func prepare(terms: [String], modelDir: URL) -> (hotwords: URL, vocab: URL)? {
        let tokens = modelDir.appendingPathComponent("tokens.txt")
        guard let text = try? String(contentsOf: tokens, encoding: .utf8) else { return nil }
        let vocab = text.split(separator: "\n").enumerated().compactMap { i, line -> String? in
            guard let piece = line.split(separator: " ").first else { return nil }
            return "\(piece)\t\(-i)"
        }.joined(separator: "\n") + "\n"
        let vocabURL = dir.appendingPathComponent("bpe.vocab")
        let hotwordsURL = dir.appendingPathComponent("hotwords.txt")
        let list = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try vocab.write(to: vocabURL, atomically: true, encoding: .utf8)
            try (list.joined(separator: "\n") + "\n").write(to: hotwordsURL, atomically: true, encoding: .utf8)
        } catch {
            Log.warn("HOTWORDS could not write files: \(error.localizedDescription)")
            return nil
        }
        Log.info("HOTWORDS \(list.count) terms")
        return (hotwordsURL, vocabURL)
    }
}
