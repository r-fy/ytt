import AVFoundation

// AVAudioEngine tap on the default input, converted to 16 kHz mono float32.
// Engine runs only during a hold so the orange mic dot matches the key.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let maxSeconds: Double = 120

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var captured: [Float] = []
    private var recording = false
    private var capTimer: DispatchWorkItem?

    var onCapReached: (() -> Void)?

    var isRecording: Bool { recording }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func start() -> Bool {
        guard !recording else { return true }
        let t0 = Date()
        captured.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            Log.warn("No input device")
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.warn("Cannot build converter from \(inputFormat)")
            return false
        }
        let ratio = AudioRecorder.sampleRate / inputFormat.sampleRate
        let target = targetFormat

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            let n = Int(out.frameLength)
            guard n > 0, let p = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: p, count: n))
            DispatchQueue.main.async {
                guard let self, self.recording else { return }
                self.captured.append(contentsOf: chunk)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.warn("engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
        recording = true
        Log.info("REC_START engineStart=\(Int(Date().timeIntervalSince(t0) * 1000))ms input=\(Int(inputFormat.sampleRate))Hz")

        let cap = DispatchWorkItem { [weak self] in
            Log.warn("cap of \(Int(AudioRecorder.maxSeconds))s hit")
            self?.onCapReached?()
        }
        capTimer = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecorder.maxSeconds, execute: cap)
        return true
    }

    // 16-bit PCM WAV so any player or tool opens it.
    static func saveWav(_ samples: [Float], to path: String) {
        do {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                if let dst = buf.floatChannelData?[0], let base = src.baseAddress {
                    dst.update(from: base, count: samples.count)
                }
            }
            try file.write(from: buf)
        } catch {
            Log.warn("saveWav failed: \(error.localizedDescription)")
        }
    }

    // Returns the samples, or nil when discarding or not recording.
    func stop(discard: Bool) -> [Float]? {
        guard recording else { return nil }
        recording = false
        capTimer?.cancel()
        capTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let seconds = Double(captured.count) / AudioRecorder.sampleRate
        if discard {
            Log.info("REC_DISCARD \(String(format: "%.2f", seconds))s")
            return nil
        }
        Log.info("REC_STOP \(String(format: "%.2f", seconds))s")
        return captured
    }
}
