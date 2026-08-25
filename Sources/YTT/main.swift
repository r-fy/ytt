import AppKit

// `YTT --clean "some text"` prints the cleaned text and exits. The runnable
// check for the rules engine: tools/check-rules.sh uses it.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--clean" {
    let pipeline = CleanupPipeline(rules: RulesEngine())
    print(pipeline.run(CommandLine.arguments[2...].joined(separator: " ")))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Never take focus: paste lands in whatever app was frontmost when Globe was released.
app.setActivationPolicy(.accessory)
app.run()
