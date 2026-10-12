import Foundation

// Stage one, rules, is synchronous and always on. Stage two, the local
// Ollama model (OllamaFormatter.swift), is async, off by default, and never
// allowed to block the paste: it races a hard deadline and falls back to
// rules-only text on timeout, error, or a failed safety check. Nothing
// downstream knows which stages ran.
final class CleanupPipeline {
    private let rules: RulesEngine
    private let ollama = OllamaFormatter()
    // Bumped once per run() call so a late Ollama reply from an earlier
    // dictation can be told apart from the one currently in flight.
    private var generation = 0
    // Backstop above OllamaFormatter's own 9 s request timeout, in case a
    // hung connect doesn't trip that timeout promptly.
    private static let hardDeadline: TimeInterval = 9.5

    init(rules: RulesEngine) { self.rules = rules }

    // Rules-only pass. Used by --clean and as the base text for the async
    // pipeline below; identical to today's behavior when the LLM stage is off.
    func run(_ raw: String) -> String {
        let text = rules.apply(raw)
        if text != raw { Log.info("CLEANUP rules changed the text") }
        return text
    }

    // Full pipeline. Always calls completion exactly once, on the main
    // queue. When the LLM stage is off, this is synchronous-in-effect (the
    // completion fires immediately, same text as run(_:)).
    func run(_ raw: String, completion: @escaping (String) -> Void) {
        let rulesText = run(raw)
        guard OllamaFormatter.isEnabled else { completion(rulesText); return }

        generation += 1
        let myGeneration = generation
        var didFinish = false

        let deadline = DispatchWorkItem {
            guard !didFinish else { return }
            didFinish = true
            Log.warn("CLEANUP ollama missed deadline, using rules-only text")
            completion(rulesText)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CleanupPipeline.hardDeadline, execute: deadline)

        ollama.format(rulesText) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !didFinish else { return }
                // A newer dictation has started since this call went out;
                // its own deadline timer (still pending) will complete it.
                guard myGeneration == self.generation else {
                    Log.info("CLEANUP ollama stale response discarded")
                    return
                }
                deadline.cancel()
                didFinish = true
                switch result {
                case .success(let cleaned):
                    if OllamaFormatter.passesSafetyCheck(input: rulesText, output: cleaned) {
                        Log.info("CLEANUP ollama changed the text")
                        completion(cleaned)
                    } else {
                        Log.warn("CLEANUP ollama rejected: token check failed")
                        completion(rulesText)
                    }
                case .failure(let error):
                    Log.warn("CLEANUP ollama request failed: \(error.localizedDescription)")
                    completion(rulesText)
                }
            }
        }
    }
}
