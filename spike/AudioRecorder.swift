// Mic capture shared by the spikes: AVAudioEngine tap on the default input,
// converted to 16 kHz mono float32, accumulated for the length of the hold.

import AVFoundation

let targetRate: Double = 16_000
let maxRecordSeconds: Double = 120
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!

private let engine = AVAudioEngine()
private var converter: AVAudioConverter?
private var captured: [Float] = []
private var recording = false
private var capTimer: DispatchWorkItem?

// Blocks until macOS answers. Exits 2 if the mic is denied.
func requireMicPermission() {
    let sema = DispatchSemaphore(value: 0)
    var ok = false
    AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sema.signal() }
    sema.wait()
    emit("MIC_PERMISSION \(ok ? "granted" : "DENIED")")
    guard ok else { exit(2) }
}

func startRecording() {
    guard !recording else { return }
    let t0 = Date()
    captured.removeAll(keepingCapacity: true)

    let input = engine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else {
        emitWarning("No input device (sample rate 0)")
        return
    }
    guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        emitWarning("Cannot build converter from \(inputFormat)")
        return
    }
    converter = conv

    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        let ratio = targetRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            emitWarning("convert error: \(error.localizedDescription)")
            return
        }
        let n = Int(out.frameLength)
        if n > 0, let p = out.floatChannelData?[0] {
            let chunk = Array(UnsafeBufferPointer(start: p, count: n))
            DispatchQueue.main.async {
                guard recording else { return }
                captured.append(contentsOf: chunk)
            }
        }
    }

    do {
        engine.prepare()
        try engine.start()
    } catch {
        emitWarning("engine start failed: \(error.localizedDescription)")
        input.removeTap(onBus: 0)
        return
    }
    recording = true
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    emit("REC_START engineStart=\(ms)ms input=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")

    // Hard cap so a stuck key never records forever.
    let cap = DispatchWorkItem {
        emitWarning("cap of \(Int(maxRecordSeconds))s hit, stopping")
        onRecordingCapped()
    }
    capTimer = cap
    DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordSeconds, execute: cap)
}

// Set by the main file if it wants to act when the cap fires.
var onRecordingCapped: () -> Void = {}

// Returns the 16 kHz samples, or nil when discarding.
func stopRecording(discard: Bool) -> [Float]? {
    guard recording else { return nil }
    recording = false
    capTimer?.cancel()
    capTimer = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    let seconds = Double(captured.count) / targetRate
    if discard {
        emit("REC_DISCARD \(String(format: "%.2f", seconds))s")
        return nil
    }
    let peak = captured.map { abs($0) }.max() ?? 0
    emit("REC_STOP \(String(format: "%.2f", seconds))s samples=\(captured.count) peak=\(String(format: "%.3f", peak))")
    return captured
}
