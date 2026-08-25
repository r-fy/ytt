// Phase 2: hold Globe, speak, release, see the words printed.
//
// Spawns the vendored sherpa websocket server once at launch, records on
// FN_DOWN, sends the samples on FN_UP, prints the transcript and timings.

import Foundation

let spikeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let repoRoot = spikeDir.deletingLastPathComponent()
let paths = SherpaPaths(
    serverBinary: repoRoot.appendingPathComponent("vendor/sherpa/bin/sherpa-onnx-offline-websocket-server"),
    // Phase 2 borrows OpenWhispr's cached model. Phase 6 replaces this with ModelStore.
    modelDir: URL(fileURLWithPath: NSHomeDirectory() + "/.cache/openwhispr/parakeet-models/parakeet-unified-en-0.6b")
)

requireMicPermission()

let sherpa = SherpaProcess(paths: paths)
do { try sherpa.start() } catch {
    emitWarning("cannot start sherpa: \(error.localizedDescription)")
    exit(3)
}

var serverReady = false
sherpa.whenReady { serverReady = true }

func transcribe(_ samples: [Float]) {
    guard serverReady else {
        emitWarning("engine still warming up, dropped \(samples.count) samples")
        return
    }
    let t0 = Date()
    SherpaWebSocketEngine.transcribe(samples: samples, port: sherpa.port) { result in
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        switch result {
        case .success(let text):
            emit("TEXT decode=\(ms)ms audio=\(String(format: "%.2f", Double(samples.count) / targetRate))s rss=\(SherpaProcess.rssMB(sherpa.pid))MB")
            emit("    \"\(text)\"")
        case .failure(let e):
            emitWarning("transcribe failed after \(ms)ms: \(e.localizedDescription)")
        }
    }
}

onRecordingCapped = { if let s = stopRecording(discard: false) { transcribe(s) } }
onFnDown = { startRecording() }
onFnUp = { interrupted in if let s = stopRecording(discard: interrupted) { transcribe(s) } }

// Stop the child when we go.
let previousShutdown = onShutdown
onShutdown = { sherpa.stop(); previousShutdown() }

runGlobeListener()
