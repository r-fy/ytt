import Foundation

// Transcriber over the sherpa offline websocket server.
// Wire format, verified in Phases 1 and 2:
//   [int32 LE sampleRate][int32 LE byteCount][float32 samples...]
// One text frame back (JSON with "text", or bare text), then we send "Done".
final class SherpaWebSocketEngine: Transcriber {
    private let process: SherpaProcess
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(serverBinary: URL, modelDir: URL) {
        process = SherpaProcess(serverBinary: serverBinary, modelDir: modelDir)
    }

    var onReady: (() -> Void)? {
        get { process.onReady }
        set { process.onReady = newValue }
    }
    var onDied: (() -> Void)? {
        get { process.onDied }
        set { process.onDied = newValue }
    }

    func enableHotwords(file: URL, bpeVocab: URL) {
        process.hotwordsFile = file
        process.bpeVocabFile = bpeVocab
    }

    var isReady: Bool { process.isReady }
    func start() { process.start() }
    func stop() { process.stop() }

    func transcribe(samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "ws://127.0.0.1:\(process.port)")!
        let task = session.webSocketTask(with: url)
        task.resume()
        let lock = NSLock()
        var done = false
        let finish: (Result<String, Error>) -> Void = { [weak self] r in
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return }
            task.send(.string("Done")) { _ in task.cancel(with: .normalClosure, reason: nil) }
            DispatchQueue.main.async {
                if case .success = r { self?.process.noteSuccess() }
                completion(r)
            }
        }
        // Watchdog: a server that accepts the audio but never answers must
        // not leave the app stuck on "Transcribing" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            finish(.failure(NSError(domain: "YTT", code: 3, userInfo: [NSLocalizedDescriptionKey: "no reply from the speech server in 30 s"])))
        }
        task.send(.data(SherpaWebSocketEngine.payload(samples: samples, sampleRate: Int32(AudioRecorder.sampleRate)))) { error in
            if let error { return finish(.failure(error)) }
            task.receive { result in
                switch result {
                case .failure(let e): finish(.failure(e))
                case .success(.string(let s)): finish(.success(SherpaWebSocketEngine.parse(s)))
                case .success(.data(let d)): finish(.success(SherpaWebSocketEngine.parse(String(data: d, encoding: .utf8) ?? "")))
                @unknown default: finish(.success(""))
                }
            }
        }
    }

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
}
