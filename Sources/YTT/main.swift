import AppKit
import AVFoundation

// `YTT --clean "some text"` prints the cleaned text and exits. The runnable
// check for the rules engine: tools/check-rules.sh uses it. Also the
// standalone check for the optional Ollama stage (OllamaFormatter.swift):
// with `llmCleanup` on, this exercises the same async pipeline AppDelegate
// uses. No NSApplication run loop is started in this branch, so the wait
// below pumps RunLoop.main directly -- DispatchQueue.main only drains once
// something is actually running the main run loop.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--clean" {
    let pipeline = CleanupPipeline(rules: RulesEngine())
    var result: String?
    pipeline.run(CommandLine.arguments[2...].joined(separator: " ")) { result = $0 }
    while result == nil {
        RunLoop.main.run(mode: .default, before: .distantFuture)
    }
    print(result!)
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

// `YTT --stitch-test "a|b|c" [comma,separated,protected]` runs Seam.stitch
// over pipe-separated pieces and prints the result. The runnable check for
// seam stitching: tools/check-rules.sh uses it. Does not construct a
// RulesEngine, so it never touches the real data folder.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--stitch-test" {
    let pieces = CommandLine.arguments[2].components(separatedBy: "|")
    let protected: Set<String>
    if CommandLine.arguments.count >= 4, !CommandLine.arguments[3].isEmpty {
        protected = Set(CommandLine.arguments[3].components(separatedBy: ",").map { $0.lowercased() })
    } else {
        protected = []
    }
    print(Seam.stitch(pieces, protected: protected))
    exit(0)
}

// `YTT --join-test "text|pause||text|pause" [off]` runs Seam.join over
// pieces separated by `||`, each `text|pause`. Optional third argument
// `off` turns paragraphs off. The runnable check for paragraph breaks:
// tools/check-rules.sh uses it. Builds a RulesEngine (check-rules.sh points
// that at a scratch dir via YTT_DATA_DIR_OVERRIDE) to run applyWords on
// each piece before joining, same as a real chunk would get.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--join-test" {
    let rules = RulesEngine()
    let paragraphsOn = !(CommandLine.arguments.count >= 4 && CommandLine.arguments[3] == "off")
    let chunks: [Seam.Chunk] = CommandLine.arguments[2].components(separatedBy: "||").map { piece in
        let parts = piece.components(separatedBy: "|")
        let text = rules.applyWords(parts[0])
        let pause = parts.count >= 2 ? Double(parts[1]) ?? 0 : 0
        return Seam.Chunk(text: text, pauseAfter: pause)
    }
    let joined = Seam.join(chunks: chunks, paragraphsOn: paragraphsOn, protected: [], sentence: rules.applySentence)
    print(joined.replacingOccurrences(of: "\n\n", with: " <P> "))
    exit(0)
}

// A flag typed with a missing argument (e.g. `YTT --join-test` alone) used to
// match none of the blocks above and fall through into a second menu-bar app
// launch, which fights the one already running for the Globe key and kills
// its speech server. Catch any unrecognized or incomplete `--flag` here and
// exit instead of launching.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--") {
    FileHandle.standardError.write(Data("YTT: unknown or incomplete flag. Usage: --clean TEXT | --chunk-test FILE.wav | --stitch-test \"a|b\" [protected] | --join-test \"text|pause||...\" [off]\n".utf8))
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Never take focus: paste lands in whatever app was frontmost when Globe was released.
app.setActivationPolicy(.accessory)
app.run()
