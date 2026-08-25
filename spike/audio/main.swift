// Phase 1: record the mic while Globe is held, save 16 kHz mono WAV.
//
// Start the engine on FN_DOWN, stop on FN_UP, discard on interrupt.
// Output: /tmp/ytt-last.wav (16-bit PCM so any player opens it).

import AVFoundation

let outputPath = "/tmp/ytt-last.wav"

func saveWav(_ samples: [Float]) {
    let t0 = Date()
    do {
        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buf.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        try file.write(from: buf)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        emit("REC_SAVED \(outputPath) write=\(ms)ms")
    } catch {
        emitWarning("write failed: \(error.localizedDescription)")
    }
}

requireMicPermission()
onRecordingCapped = { if let s = stopRecording(discard: false) { saveWav(s) } }
onFnDown = { startRecording() }
onFnUp = { interrupted in if let s = stopRecording(discard: interrupted) { saveWav(s) } }
runGlobeListener()
