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
        SherpaProcess.killOrphans(of: serverBinary)
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
        // The server has no bind-address flag and would listen on every
        // interface. libbindfix rewrites its wildcard bind to 127.0.0.1.
        let bindfix = serverBinary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libbindfix.dylib")
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = bindfix.path
        p.environment = env
        // The server writes a connection log named log.txt into its working
        // directory. Keep that out of the repo and out of the user's folders.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
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
                Log.warn("sherpa: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
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

    // Polite terminate, then SIGKILL if it lingers, so no 1 GB orphan survives us.
    func stop() {
        stopping = true
        isReady = false
        guard let process, process.isRunning else { self.process = nil; return }
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        self.process = nil
    }

    // Called after a successful transcription: the server is proven healthy,
    // so the restart budget resets. Resetting on "Started!" alone would let a
    // server that loads fine but crashes on every decode respawn forever.
    func noteSuccess() {
        restarts = 0
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        Log.info("SHERPA_READY loadTime=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        onReady?()
    }

    private func handleExit(_ proc: Process) {
        isReady = false
        guard !stopping else { return }
        Log.warn("SHERPA_EXITED status=\(proc.terminationStatus)")
        onDied?()
        guard restarts < 3 else {
            Log.warn("sherpa died 3 times, giving up until relaunch")
            return
        }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    // A force-quit or crash of YTT skips stop(), leaving a server behind.
    // Reap any process running our bundled binary before spawning a new one.
    static func killOrphans(of binary: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", binary.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != getpid() {
                Log.warn("killing orphaned sherpa pid=\(pid)")
                kill(pid, SIGKILL)
            }
        }
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
