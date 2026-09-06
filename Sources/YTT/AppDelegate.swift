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
    private var targetAtRelease: pid_t?
    private var current: Dictation?   // the hold in progress; each hold owns its own state
    static let lastAudioPath = NSHomeDirectory() + "/Library/Application Support/YTT/last.wav"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("YTT launched pid=\(getpid()) accessibility=\(AXIsProcessTrusted())")
        statusBar = StatusBarController()
        statusBar.onQuit = { [weak self] in self?.quit() }
        statusBar.onRestart = { [weak self] in self?.restart() }

        let resources = Bundle.main.resourceURL!
        engine = SherpaWebSocketEngine(
            serverBinary: resources.appendingPathComponent("bin/sherpa-onnx-offline-websocket-server"),
            modelDir: modelStore.modelDir
        )
        engine.onReady = { [weak self] in self?.statusBar.set(.idle) }
        engine.onDied = { [weak self] in self?.statusBar.set(.error("Speech engine stopped")) }

        if !AXIsProcessTrusted() {
            // Shows the system prompt that deep-links to the Accessibility pane.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            statusBar.blockingIssue = "Grant Accessibility, then quit and reopen YTT"
        }

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
        recorder.onChunk = { [weak self] chunk in self?.current?.add(chunk) }

        // Ask for the mic now so the first hold never races a permission dialog.
        AudioRecorder.requestPermission { [weak self] ok in
            Log.info("MIC_PERMISSION \(ok ? "granted" : "DENIED")")
            if !ok { self?.statusBar.blockingIssue = "Microphone permission missing (System Settings > Privacy & Security)" }
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
        rules.reloadIfChanged()
        recorder.chunking = rules.chunkedDecodeEnabled
        if recorder.start() {
            var protectedWords: Set<String> = []
            for term in rules.dictionaryTerms {
                protectedWords.insert(term.lowercased())
                if let firstWord = term.split(separator: " ").first {
                    protectedWords.insert(firstWord.lowercased())
                }
            }
            current = Dictation(engine: engine, protectedWords: protectedWords)
            statusBar.set(.recording)
        }
    }

    func globeKeyUp(interrupted: Bool, heldSeconds: Double) {
        guard recorder.isRecording else { return }
        Log.info("FN_UP held=\(Int(heldSeconds * 1000))ms")
        targetAtRelease = NSWorkspace.shared.frontmostApplication?.processIdentifier
        finishRecording(discard: interrupted)
    }

    private func finishRecording(discard: Bool) {
        let dictation = current
        current = nil
        guard let rec = recorder.stop(discard: discard), let dictation else {
            statusBar.set(.idle)
            return
        }
        // Under a quarter second is a tap, not a dictation.
        guard Double(rec.all.count) / AudioRecorder.sampleRate >= 0.25 else {
            statusBar.set(.idle)
            return
        }
        statusBar.set(.transcribing)
        // Kept for debugging and for A/B tests on the same audio. One file, overwritten.
        AudioRecorder.saveWav(rec.all, to: AppDelegate.lastAudioPath)
        let t0 = Date()
        let target = targetAtRelease
        let audioSeconds = Double(rec.all.count) / AudioRecorder.sampleRate
        if rec.tail.count == rec.all.count {
            // Nothing was cut during the hold, so the tail is the whole
            // recording. The hasSpeech gate below only exists to skip a
            // pointless decode of the silence that follows a pause-cut; it
            // does not apply when no chunk has been sent yet.
            dictation.add(rec.tail)
        } else if Double(rec.tail.count) / AudioRecorder.sampleRate >= 0.25,
                  AudioRecorder.hasSpeech(rec.tail, above: rec.silenceRMS) {
            dictation.add(rec.tail)
        }
        dictation.finish { [weak self] result in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            switch result {
            case .success(let text):
                // The words themselves go to history.jsonl, not the log.
                Log.info("TEXT decode=\(ms)ms audio=\(String(format: "%.2f", audioSeconds))s chars=\(text.count)")
                let cleaned = self.cleanup.run(text)
                if !cleaned.isEmpty {
                    TextInjector.insert(cleaned, intendedTarget: target)
                    self.statusBar.setLast(cleaned)
                    History.record(
                        app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                        raw: text, cleaned: cleaned,
                        audioSeconds: audioSeconds, decodeMs: ms)
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

    // The relauncher must wait for this process to exit first, or the new
    // instance races the old one over the Globe key preference restore.
    private func restart() {
        Log.info("RESTART requested")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c",
            "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; " +
            "/usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        do {
            try helper.run()
        } catch {
            Log.warn("restart helper failed to launch: \(error.localizedDescription)")
            return
        }
        quit()
    }
}

// Chunks cut mid-sentence decode separately, so the model has no idea the
// previous chunk was left hanging: it capitalizes the next chunk's first
// word as if a fresh sentence started. Seam.stitch patches that join back up
// without ever touching a chunk's own words, only the space between two of
// them.
enum Seam {
    static func stitch(_ pieces: [String], protected: Set<String>) -> String {
        let alwaysProtected: Set<String> = protected.union(["i", "i'm", "i'll", "i've", "i'd"])
        let kept = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !kept.isEmpty else { return "" }

        var result = [kept[0]]
        for i in 1..<kept.count {
            let previous = kept[i - 1]
            let piece = kept[i]
            if let last = previous.last, ".?!:".contains(last) {
                result.append(piece)
                continue
            }
            result.append(Seam.lowercasedFirstWordIfSafe(piece, protected: alwaysProtected))
        }
        return result.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lowercasedFirstWordIfSafe(_ piece: String, protected: Set<String>) -> String {
        guard let firstWordRange = piece.range(of: "\\S+", options: .regularExpression) else { return piece }
        let firstWord = piece[firstWordRange]
        var core = Substring(firstWord)
        while let f = core.first, !f.isLetter { core = core.dropFirst() }
        while let l = core.last, !l.isLetter { core = core.dropLast() }
        let normalizedCore = core.replacingOccurrences(of: "\u{2019}", with: "'")

        if protected.contains(normalizedCore.lowercased()) { return piece }
        let letterCount = normalizedCore.filter { $0.isLetter }.count
        if letterCount >= 2, normalizedCore == normalizedCore.uppercased() { return piece }
        let firstTwo = Array(normalizedCore.prefix(2))
        if firstTwo.count == 2, firstTwo[0].isUppercase, firstTwo[1].isUppercase { return piece }

        guard let first = piece.first, first.isUppercase else { return piece }
        return String(first).lowercased() + piece.dropFirst()
    }
}

// One hold of the key. Chunks cut during the hold go to the server right
// away, so after release only the tail is left to decode. Sends run one at
// a time: the server shares four threads across connections, so parallel
// requests would not finish sooner, and one at a time keeps the order
// trivial. Results still land in slots by index, so a join is always in order.
private final class Dictation {
    private let engine: Transcriber
    private var texts: [String?] = []
    private var queue: [(index: Int, samples: [Float])] = []
    private var sending = false
    private var failure: Error?
    private var onDone: ((Result<String, Error>) -> Void)?
    private let protectedWords: Set<String>

    init(engine: Transcriber, protectedWords: Set<String> = []) {
        self.engine = engine
        self.protectedWords = protectedWords
    }

    func add(_ samples: [Float]) {
        texts.append(nil)
        queue.append((texts.count - 1, samples))
        pump()
    }

    // Called at release. Fires once, after every slot is filled.
    func finish(_ completion: @escaping (Result<String, Error>) -> Void) {
        onDone = completion
        settle()
    }

    private func pump() {
        // failure is not part of this guard: the server most likely crashed
        // and restarted, so a chunk queued after release is worth one more
        // try. Whether a mid-flight failure drops the rest of the queue is
        // decided in the .failure branch below, keyed on onDone, not here.
        guard !sending, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        sending = true
        let t0 = Date()
        // Strong capture on purpose: after release nothing else holds this
        // object, and the reply (or the 30 s watchdog) must still reach it.
        engine.transcribe(samples: job.samples) { result in
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let seconds = String(format: "%.2f", Double(job.samples.count) / AudioRecorder.sampleRate)
            self.sending = false
            switch result {
            case .success(let text):
                Log.info("CHUNK \(job.index) decode=\(ms)ms audio=\(seconds)s chars=\(text.count)")
                self.texts[job.index] = text
            case .failure(let e):
                Log.warn("CHUNK \(job.index) failed after \(ms)ms: \(e.localizedDescription)")
                self.failure = e
                // A dropped chunk must not leave its slot nil forever, or settle()
                // would wait on it forever.
                self.texts[job.index] = ""
                // Mid-hold a failure means the server is likely down, so drop what is
                // queued rather than pay a watchdog wait per chunk. After release the
                // queue holds only the tail, which is worth one more try.
                if self.onDone == nil {
                    for pending in self.queue { self.texts[pending.index] = "" }
                    self.queue.removeAll()
                }
            }
            self.pump()
            self.settle()
        }
    }

    // Waits until every slot is filled, then reports failure only when
    // nothing joined, so one bad chunk cannot discard text that decoded fine.
    private func settle() {
        guard let onDone, texts.allSatisfy({ $0 != nil }) else { return }
        self.onDone = nil
        let joined = Seam.stitch(texts.compactMap { $0 }, protected: protectedWords)
        if joined.isEmpty, let failure { onDone(.failure(failure)) } else { onDone(.success(joined)) }
    }
}
