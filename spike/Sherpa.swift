// sherpa-onnx offline websocket server: spawn it once, keep it resident,
// send one binary message per dictation.
//
// Wire format (verified against OpenWhispr's parakeetWsServer.js and by a
// Python client in Phase 1):
//   [int32 LE sampleRate][int32 LE byteCount][float32 samples...]
// Server replies with one text frame (JSON with "text", or bare text),
// then the client sends the string "Done".

import Foundation

struct SherpaPaths {
    let serverBinary: URL
    let modelDir: URL
}

final class SherpaProcess {
    let paths: SherpaPaths
    let port: Int
    private let process = Process()
    private var ready = false
    private var readyCallbacks: [() -> Void] = []
    private let startedAt = Date()

    init(paths: SherpaPaths, threads: Int = 4) {
        self.paths = paths
        self.port = SherpaProcess.freePort()
        let m = paths.modelDir.path
        process.executableURL = paths.serverBinary
        process.arguments = [
            "--tokens=\(m)/tokens.txt",
            "--encoder=\(m)/encoder.int8.onnx",
            "--decoder=\(m)/decoder.int8.onnx",
            "--joiner=\(m)/joiner.int8.onnx",
            "--port=\(port)",
            "--num-threads=\(threads)",
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if text.contains("Started!") {
                DispatchQueue.main.async { self?.markReady() }
            }
            if text.contains("Error") || text.contains("error") {
                emitWarning("sherpa: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        process.terminationHandler = { p in
            DispatchQueue.main.async {
                emitWarning("SHERPA_EXITED status=\(p.terminationStatus) reason=\(p.terminationReason.rawValue)")
            }
        }
    }

    var pid: Int32 { process.processIdentifier }

    func start() throws {
        try process.run()
        emit("SHERPA_SPAWNED pid=\(process.processIdentifier) port=\(port)")
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    func whenReady(_ block: @escaping () -> Void) {
        if ready { block() } else { readyCallbacks.append(block) }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        emit("SHERPA_READY loadTime=\(ms)ms rss=\(SherpaProcess.rssMB(pid))MB")
        readyCallbacks.forEach { $0() }
        readyCallbacks.removeAll()
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

    static func rssMB(_ pid: Int32) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }
}

enum SherpaWebSocketEngine {
    static func payload(samples: [Float], sampleRate: Int32) -> Data {
        var data = Data(capacity: 8 + samples.count * 4)
        var rate = sampleRate.littleEndian
        var bytes = Int32(samples.count * 4).littleEndian
        data.append(Data(bytes: &rate, count: 4))
        data.append(Data(bytes: &bytes, count: 4))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    static func parse(_ reply: String) -> String {
        if let d = reply.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let text = obj["text"] as? String {
            return text
        }
        return reply
    }

    // One connection per dictation. Calls back on the main queue.
    static func transcribe(samples: [Float], port: Int, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let finish: (Result<String, Error>) -> Void = { r in
            task.send(.string("Done")) { _ in task.cancel(with: .normalClosure, reason: nil) }
            DispatchQueue.main.async { completion(r) }
        }
        task.send(.data(payload(samples: samples, sampleRate: Int32(targetRate)))) { error in
            if let error { return finish(.failure(error)) }
            task.receive { result in
                switch result {
                case .failure(let e): finish(.failure(e))
                case .success(.string(let s)): finish(.success(parse(s)))
                case .success(.data(let d)): finish(.success(parse(String(data: d, encoding: .utf8) ?? "")))
                @unknown default: finish(.success(""))
                }
            }
        }
    }
}
