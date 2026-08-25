import AppKit

enum AppState {
    case warming, downloading(Double), idle, recording, transcribing, error(String)
}

final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateLine = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let permissionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var onQuit: (() -> Void)?

    init() {
        let menu = NSMenu()
        menu.addItem(stateLine)
        menu.addItem(permissionLine)
        menu.addItem(lastLine)
        menu.addItem(.separator())
        let rulesItem = NSMenuItem(title: "Edit cleanup rules", action: #selector(openRules), keyEquivalent: "")
        rulesItem.target = self
        menu.addItem(rulesItem)
        let updates = NSMenuItem(title: "Check for model updates", action: #selector(openModelReleases), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit YTT", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        stateLine.isEnabled = false
        permissionLine.isEnabled = false
        lastLine.isEnabled = false
        lastLine.isHidden = true
        set(.warming)
        refreshPermissions()
    }

    func set(_ state: AppState) {
        let (symbol, text): (String, String)
        switch state {
        case .warming: (symbol, text) = ("hourglass", "Loading speech model")
        case .downloading(let p): (symbol, text) = ("arrow.down.circle", "Downloading speech model \(Int(p * 100))%")
        case .idle: (symbol, text) = ("mic", "Ready. Hold Globe to talk")
        case .recording: (symbol, text) = ("mic.fill", "Recording")
        case .transcribing: (symbol, text) = ("ellipsis.circle", "Transcribing")
        case .error(let msg): (symbol, text) = ("exclamationmark.triangle", msg)
        }
        // Idle stays a gray template glyph. Recording lights up red, transcribing
        // amber, so the menu bar itself shows the state at a glance.
        let tint: NSColor?
        switch state {
        case .recording: tint = .systemRed
        case .transcribing: tint = .systemOrange
        case .error: tint = .systemYellow
        default: tint = nil
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        if let tint, let base = image {
            image = base.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        item.button?.image = image
        item.button?.toolTip = text
        stateLine.title = text
    }

    func setLast(_ text: String) {
        let short = text.count > 60 ? String(text.prefix(57)) + "..." : text
        lastLine.title = "Last: \(short)"
        lastLine.isHidden = false
    }

    func refreshPermissions() {
        let ax = AXIsProcessTrusted() ? "granted" : "MISSING"
        permissionLine.title = "Accessibility: \(ax)"
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(URL(fileURLWithPath: RulesEngine.runtimePath))
    }

    // Updating the model is manual on purpose: a new model can regress on a
    // voice with no warning. Bump Resources/models.json when one is worth it.
    @objc private func openModelReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models")!)
    }

    @objc private func quitTapped() {
        onQuit?()
    }
}
