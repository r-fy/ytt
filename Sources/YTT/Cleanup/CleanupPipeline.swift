import Foundation

// Ordered stages, each String -> String. Rules are stage one. Phase 7's
// small model becomes a later stage that can be switched off. Nothing
// downstream knows which stages ran.
final class CleanupPipeline {
    private let stages: [(String, (String) -> String)]

    init(rules: RulesEngine) {
        stages = [
            ("rules", rules.apply),
        ]
    }

    func run(_ raw: String) -> String {
        var text = raw
        for (name, stage) in stages {
            let before = text
            text = stage(text)
            if text != before { Log.info("CLEANUP \(name) changed the text") }
        }
        return text
    }
}
