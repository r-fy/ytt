import Foundation

// Optional stage: reformats rules-cleaned text through a local Ollama model
// (s1-mini, picked in private/LLM_FORMAT_BENCH_2026-09-14.md and confirmed
// at scale in private/LLM_FORMAT_BENCH_S1MINI_30_2026-09-16.md) for
// punctuation, capitalization, and paragraph breaks. Off by default:
//
//   defaults write local.ytt.menubar llmCleanup -bool true
//
// then relaunch YTT (same pattern as dataDir in DataDir.swift). Talks to
// Ollama's HTTP API on 127.0.0.1 only -- confirmed 2026-09-16 via
// `lsof -i :11434` that Ollama already binds loopback-only by default, so no
// bindfix.c-style interposer is needed here.
final class OllamaFormatter {
    // Read once at launch, matching DataDir's pattern: flipping the default
    // needs a relaunch, never a mid-run surprise.
    static let isEnabled = UserDefaults.standard.bool(forKey: "llmCleanup")

    private static let url = URL(string: "http://127.0.0.1:11434/api/generate")!
    private static let model = "s1-mini-native"

    // s1-mini only behaves with its documented native control-line prompt,
    // never a generic system prompt (a normal templated chat call leaks a
    // <think> tag into the output -- see the 2026-09-16 bench doc). So this
    // stage sends a raw completion with the exact prompt shape the bench
    // confirmed clean: a manually closed think block, since raw mode
    // bypasses whatever "think": false does for templated calls.
    private static let systemPrompt = """
    You are a text normalizer for speech-to-text transcripts. The input \
    begins with a control line specifying the styling, structure, and \
    context settings; clean the transcript to match those settings and \
    output only the cleaned text.
    """

    private static let controlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    private static func rawPrompt(for transcript: String) -> String {
        """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(controlLine)
        \(transcript)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }

    // The benchmark's observed max latency was ~9 s; this is the request's
    // own ceiling. CleanupPipeline layers a second, slightly longer hard
    // deadline on top so a hung connect (which this timeout does not always
    // catch) can never block the paste.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 9
        cfg.timeoutIntervalForResource = 9
        return URLSession(configuration: cfg)
    }()

    enum FormatError: Error { case badResponse }

    // completion runs on an arbitrary queue; callers hop back to main as needed.
    func format(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": OllamaFormatter.model,
            "prompt": OllamaFormatter.rawPrompt(for: text),
            "raw": true,
            "stream": false,
            "options": ["temperature": 0, "num_ctx": 4096],
        ]
        var req = URLRequest(url: OllamaFormatter.url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else {
                completion(.failure(FormatError.badResponse))
                return
            }
            completion(.success(response.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }

    // Rejects an LLM output that dropped or altered a number or proper-noun-
    // ish token from the input, so a "helpful" rewrite (e.g. s1-mini's
    // occasional clause-drop seen in the 30-sample benchmark) never reaches
    // the paste.
    static func passesSafetyCheck(input: String, output: String) -> Bool {
        for token in sensitiveTokens(in: input) where !output.contains(token) {
            return false
        }
        return true
    }

    private static func sensitiveTokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            guard !word.isEmpty else { return nil }
            if word.contains(where: { $0.isNumber }) { return word }
            let upperIndices = word.indices.filter { word[$0].isUppercase }
            guard let first = upperIndices.first else { return nil }
            // ALL CAPS (length > 1), or an uppercase letter beyond simple
            // sentence-initial capitalization (more than one, or not first).
            if upperIndices.count > 1 || first != word.startIndex { return word }
            return nil
        }
    }
}
