import Foundation

// Spawns sherpa-onnx-offline-websocket-server once, keeps it resident,
// restarts it if it dies. Same launch arguments OpenWhispr uses.
final class SherpaProcess {
    let serverBinary: URL
    let modelDir: URL
    private(set) var port: Int = 0
    private var process: Process?
    private(set) var isReady = false
    private var startedAt = Date()
    private var restarts = 0
    private var stopping = false

    var onReady: (() -> Void)?
    var onDied: (() -> Void)?

    // Hotwords bias recognition toward known names. Needs beam search and a
    // BPE vocab (built from tokens.txt, see Hotwords.swift). Score 1.5 was the
    // Phase 6 sweet spot: 2.0 started dropping neighbouring words.
    var hotwordsFile: URL?
    var bpeVocabFile: URL?
    var hotwordsScore: Double = 1.5

    init(serverBinary: URL, modelDir: URL) {
        self.serverBinary = serverBinary
        self.modelDir = modelDir
    }

    var pid: Int32 { process?.processIdentifier ?? 0 }

    func start() {
        stopping = false
        isReady = false
        port = SherpaProcess.freePort()
        startedAt = Date()
        let m = modelDir.path
        let p = Process()
        p.executableURL = serverBinary
        p.arguments = [
            "--tokens=\(m)/tokens.txt",
            "--encoder=\(m)/encoder.int8.onnx",
            "--decoder=\(m)/decoder.int8.onnx",
            "--joiner=\(m)/joiner.int8.onnx",
            "--port=\(port)",
            "--num-threads=4",
        ]
        if let hotwordsFile, let bpeVocabFile {
            p.arguments! += [
                "--decoding-method=modified_beam_search",
                "--hotwords-file=\(hotwordsFile.path)",
                "--hotwords-score=\(hotwordsScore)",
                "--modeling-unit=bpe",
                "--bpe-vocab=\(bpeVocabFile.path)",
            ]
        }
        let stderrPipe = Pipe()
        p.standardError = stderrPipe
        p.standardOutput = FileHandle.nullDevice
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if text.contains("Started!") {
                DispatchQueue.main.async { self?.markReady() }
            }
            if text.lowercased().contains("error") {
                Log.warn("sherpa: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(proc) }
        }
        do {
            try p.run()
            process = p
            Log.info("SHERPA_SPAWNED pid=\(p.processIdentifier) port=\(port)")
        } catch {
            Log.warn("cannot start sherpa: \(error.localizedDescription)")
            onDied?()
        }
    }

    func stop() {
        stopping = true
        if let process, process.isRunning { process.terminate() }
        process = nil
        isReady = false
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        restarts = 0
        Log.info("SHERPA_READY loadTime=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        onReady?()
    }

    private func handleExit(_ proc: Process) {
        isReady = false
        guard !stopping else { return }
        Log.warn("SHERPA_EXITED status=\(proc.terminationStatus)")
        onDied?()
        // Three tries with a short pause, then give up and show the error state.
        guard restarts < 3 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    // Bind port 0 on loopback, read back what the kernel picked, release it.
    static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(sock, p, len) == 0 && getsockname(sock, p, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : 6006
    }
}
