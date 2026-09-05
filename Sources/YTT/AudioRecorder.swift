import AVFoundation

// AVAudioEngine tap on the default input, converted to 16 kHz mono float32.
// Engine runs only during a hold so the orange mic dot matches the key.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let maxSeconds: Double = 120

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var captured: [Float] = []
    private var emitted = 0            // samples already handed out through onChunk
    private var chunker = PauseChunker()
    private var recording = false
    private var capTimer: DispatchWorkItem?

    var onCapReached: (() -> Void)?
    // Called on the main queue with each finished chunk while the key is
    // still held, so the server decodes it before the hold ends.
    var onChunk: (([Float]) -> Void)?
    // Set per hold. Off keeps the whole recording for one send after release.
    var chunking = true

    struct Recording {
        let all: [Float]    // the whole hold, for last.wav and the tap rule
        let tail: [Float]   // what onChunk has not handed out yet
        let silenceRMS: Float   // the quiet threshold this hold settled on
    }

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
        emitted = 0
        chunker = PauseChunker()

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
                let start = self.captured.count
                self.captured.append(contentsOf: chunk)
                if self.chunking, let cut = self.chunker.feed(chunk, at: start) {
                    let piece = Array(self.captured[self.emitted..<cut])
                    self.emitted = cut
                    self.onChunk?(piece)
                }
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

    // Returns the recording, or nil when discarding or not recording.
    func stop(discard: Bool) -> Recording? {
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
        Log.info("REC_STOP \(String(format: "%.2f", seconds))s chunks=\(chunker.chunks) silenceRMS=\(String(format: "%.4f", chunker.threshold))")
        return Recording(all: captured, tail: Array(captured[emitted...]), silenceRMS: chunker.threshold)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // True when any 100 ms window rises above the silence threshold. Whole-clip
    // RMS would hide one short word inside a long quiet tail.
    static func hasSpeech(_ samples: [Float], above threshold: Float) -> Bool {
        let window = Int(sampleRate * PauseChunker.frameSeconds)
        return stride(from: 0, to: samples.count, by: window).contains { start in
            rms(samples[start..<min(start + window, samples.count)]) >= threshold
        }
    }
}

// Decides where to cut the live recording so chunks can be decoded during
// the hold. Cuts land inside a pause, never inside speech. Pure value type
// so `YTT --chunk-test` can run the same logic over a wav file.
// The threshold is capped at a fraction of the loudest frame heard so far,
// so a hold with no true silence never lets the threshold climb into speech
// and cut mid-word.
struct PauseChunker {
    // Levels are judged per 100 ms frame. Shorter windows flicker between
    // words; longer ones blur the edges of a pause.
    static let frameSeconds = 0.1
    // A frame is quiet when its RMS sits under `noiseFactor` times the
    // quietest frame heard so far in this hold, or under `silenceRMS` if that
    // is higher. Mic gain varies a lot: these constants are set for an
    // assumed working range (speech peaking near 0.007, room noise near
    // 0.0005), not a measurement taken from this mic, so a fixed cutoff
    // cannot work alone.
    // Missing a pause only costs speed; cutting inside a word costs text, so
    // both numbers lean toward calling a frame "speech".
    static let silenceRMS: Float = 0.002
    static let noiseFactor: Float = 3
    // A pause must be far quieter than the loudest thing heard. Without this, a hold with no true silence sets the floor from speech itself and the threshold climbs into the speech range, cutting mid-word.
    static let peakFraction: Float = 6
    // Half a second of quiet counts as a pause. Shorter gaps sit inside sentences.
    static let pauseSeconds = 0.5
    // A chunk needs at least this much audio before a pause may close it.
    static let minChunkSeconds = 4.0
    // Cut here even without a pause so no single decode runs long.
    static let maxChunkSeconds = 30.0

    private(set) var chunks = 0
    private(set) var floor: Float = .greatestFiniteMagnitude   // quietest frame so far
    private(set) var peak: Float = 0                          // loudest frame so far
    private var chunkStart = 0        // sample index where the open chunk begins
    private var silenceStart: Int?    // sample index where the current quiet run began
    private var frame: [Float] = []   // samples gathered toward the next 100 ms judgement
    private var frameStart = 0

    var threshold: Float {
        let adaptive = floor == .greatestFiniteMagnitude
            ? PauseChunker.silenceRMS
            : max(PauseChunker.silenceRMS, PauseChunker.noiseFactor * floor)
        return peak > 0 ? min(adaptive, peak / PauseChunker.peakFraction) : adaptive
    }

    // Feed one buffer that starts at sample index `start`. Returns the cut
    // index when the open chunk closes; the new chunk begins at that index.
    mutating func feed(_ buffer: [Float], at start: Int) -> Int? {
        if frame.isEmpty { frameStart = start }
        frame.append(contentsOf: buffer)
        guard frame.count >= Int(AudioRecorder.sampleRate * PauseChunker.frameSeconds) else { return nil }
        let end = frameStart + frame.count
        let rms = AudioRecorder.rms(frame[...])
        frame.removeAll(keepingCapacity: true)
        // Digital silence (mic not delivering yet) is not a noise floor.
        if rms > 1e-5 { floor = min(floor, rms) }
        peak = max(peak, rms)
        if rms < threshold {
            if silenceStart == nil { silenceStart = frameStart }
        } else {
            silenceStart = nil
        }
        let rate = AudioRecorder.sampleRate
        let minChunk = Int(rate * PauseChunker.minChunkSeconds)
        if let s = silenceStart,
           Double(end - s) / rate >= PauseChunker.pauseSeconds,
           end - chunkStart >= minChunk {
            // Middle of the quiet run, but never so early that the chunk
            // falls under the minimum when the quiet run began before it.
            let cut = max((s + end) / 2, chunkStart + minChunk)
            // The quiet run goes on past the cut; keep counting it from there.
            silenceStart = cut
            return close(at: cut)
        }
        if Double(end - chunkStart) / rate >= PauseChunker.maxChunkSeconds {
            return close(at: end)
        }
        return nil
    }

    private mutating func close(at cut: Int) -> Int {
        chunkStart = cut
        chunks += 1
        return cut
    }
}
