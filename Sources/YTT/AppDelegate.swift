import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, GlobeKeyListenerDelegate {
    private var statusBar: StatusBarController!
    private let globe = GlobeKeyListener()
    private let recorder = AudioRecorder()
    private var engine: SherpaWebSocketEngine!
    private let rules = RulesEngine()
    private lazy var cleanup = CleanupPipeline(rules: rules)
    private let modelStore = ModelStore()
    private var signalSources: [DispatchSourceSignal] = []
    static let lastAudioPath = NSHomeDirectory() + "/Library/Application Support/YTT/last.wav"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("YTT launched pid=\(getpid()) accessibility=\(AXIsProcessTrusted())")
        statusBar = StatusBarController()
        statusBar.onQuit = { [weak self] in self?.quit() }

        let resources = Bundle.main.resourceURL!
        engine = SherpaWebSocketEngine(
            serverBinary: resources.appendingPathComponent("bin/sherpa-onnx-offline-websocket-server"),
            modelDir: modelStore.modelDir
        )
        engine.onReady = { [weak self] in self?.statusBar.set(.idle) }
        engine.onDied = { [weak self] in self?.statusBar.set(.error("Speech engine stopped")) }

        modelStore.adoptExistingIfPresent()
        if modelStore.isInstalled {
            startEngine()
        } else {
            statusBar.set(.downloading(0))
            modelStore.onProgress = { [weak self] p in self?.statusBar.set(.downloading(p)) }
            modelStore.download { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.startEngine()
                case .failure: self.statusBar.set(.error("Model download failed, relaunch to retry"))
                }
            }
        }

        recorder.onCapReached = { [weak self] in self?.finishRecording(discard: false) }

        // Ask for the mic now so the first hold never races a permission dialog.
        AudioRecorder.requestPermission { ok in
            Log.info("MIC_PERMISSION \(ok ? "granted" : "DENIED")")
            if !ok { self.statusBar.set(.error("Microphone permission missing")) }
        }

        if !AXIsProcessTrusted() {
            // Shows the system prompt that deep-links to the Accessibility pane.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            statusBar.set(.error("Grant Accessibility, then relaunch"))
        }

        globe.delegate = self
        GlobeSystemAction.recoverLeftoverState()
        if globe.start() {
            GlobeSystemAction.apply()
        }

        installSignalHandlers()
        try? SMAppService.mainApp.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // Hotword list comes from the dictionary in rules.json, read at launch.
    // Editing the dictionary needs a relaunch to reach the engine; the
    // find-replace side of the same file applies on the next dictation.
    private func startEngine() {
        if rules.hotwordsEnabled,
           let files = Hotwords.prepare(terms: rules.dictionaryTerms, modelDir: modelStore.modelDir) {
            engine.enableHotwords(file: files.hotwords, bpeVocab: files.vocab)
        }
        engine.start()
    }

    // MARK: Globe key

    func globeKeyDown() {
        guard engine.isReady else {
            Log.info("FN_DOWN ignored, engine not ready")
            return
        }
        if recorder.start() {
            statusBar.set(.recording)
        }
    }

    func globeKeyUp(interrupted: Bool, heldSeconds: Double) {
        Log.info("FN_UP held=\(Int(heldSeconds * 1000))ms")
        finishRecording(discard: interrupted)
    }

    private func finishRecording(discard: Bool) {
        guard let samples = recorder.stop(discard: discard) else {
            statusBar.set(.idle)
            return
        }
        // Under a quarter second is a tap, not a dictation.
        guard Double(samples.count) / AudioRecorder.sampleRate >= 0.25 else {
            statusBar.set(.idle)
            return
        }
        statusBar.set(.transcribing)
        // Kept for debugging and for A/B tests on the same audio. One file, overwritten.
        AudioRecorder.saveWav(samples, to: AppDelegate.lastAudioPath)
        let t0 = Date()
        engine.transcribe(samples: samples) { [weak self] result in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            switch result {
            case .success(let text):
                Log.info("TEXT decode=\(ms)ms audio=\(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate))s \"\(text)\"")
                let cleaned = self.cleanup.run(text)
                if !cleaned.isEmpty {
                    TextInjector.insert(cleaned)
                    self.statusBar.setLast(cleaned)
                    History.record(
                        app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                        raw: text, cleaned: cleaned,
                        audioSeconds: Double(samples.count) / AudioRecorder.sampleRate, decodeMs: ms)
                }
                self.statusBar.set(.idle)
            case .failure(let e):
                Log.warn("transcribe failed after \(ms)ms: \(e.localizedDescription)")
                self.statusBar.set(.error("Transcription failed"))
            }
        }
    }

    // MARK: Shutdown

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.quit() }
            src.resume()
            signalSources.append(src)
        }
    }

    private var didShutdown = false
    private func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        Log.info("SHUTDOWN")
        _ = recorder.stop(discard: true)
        engine.stop()
        globe.stop()
        GlobeSystemAction.restore()
    }

    private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }
}
