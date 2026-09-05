import AppKit
import AVFoundation

// `YTT --clean "some text"` prints the cleaned text and exits. The runnable
// check for the rules engine: tools/check-rules.sh uses it.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--clean" {
    let pipeline = CleanupPipeline(rules: RulesEngine())
    print(pipeline.run(CommandLine.arguments[2...].joined(separator: " ")))
    exit(0)
}

// `YTT --chunk-test file.wav` runs the pause detector over a 16 kHz mono wav
// and prints where it would cut, in seconds. The runnable check for
// decode-while-talking: every chunk must be at least 4 s and every cut must
// sit in a quiet spot.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--chunk-test" {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.fileFormat.sampleRate == AudioRecorder.sampleRate, file.fileFormat.channelCount == 1 else {
        print("need 16 kHz mono, got \(file.fileFormat)")
        exit(2)
    }
    guard file.length > 0 else {
        print("empty wav, nothing to chunk")
        exit(2)
    }
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    let rate = AudioRecorder.sampleRate
    let step = 341 // about 20 ms, what a 48 kHz mic tap delivers after conversion
    var chunker = PauseChunker()
    var start = 0
    var levels: [Float] = []
    for at in stride(from: 0, to: samples.count, by: step) {
        let piece = Array(samples[at..<min(at + step, samples.count)])
        levels.append(AudioRecorder.rms(piece[...]))
        if let cut = chunker.feed(piece, at: at) {
            let around = AudioRecorder.rms(samples[max(cut - step, 0)..<min(cut + step, samples.count)])
            print(String(format: "chunk %d  %.2f - %.2f s  (%.2f s)  rms at cut %.4f",
                         chunker.chunks - 1, Double(start) / rate, Double(cut) / rate, Double(cut - start) / rate, around))
            start = cut
        }
    }
    print(String(format: "tail     %.2f - %.2f s  (%.2f s)", Double(start) / rate, Double(samples.count) / rate,
                 Double(samples.count - start) / rate))
    let sorted = levels.sorted()
    print(String(format: "window rms min %.4f  median %.4f  max %.4f  quiet threshold settled at %.4f",
                 sorted.first ?? 0, sorted[sorted.count / 2], sorted.last ?? 0, chunker.threshold))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Never take focus: paste lands in whatever app was frontmost when Globe was released.
app.setActivationPolicy(.accessory)
app.run()
