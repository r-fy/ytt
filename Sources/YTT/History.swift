import Foundation

// One JSON line per dictation, appended next to rules.json in the data
// folder. Later phases read this to see which errors the rules miss and to
// learn from corrections made after the paste.
enum History {
    static var path: String { DataDir.url.appendingPathComponent("history.jsonl").path }

    struct Entry: Encodable {
        let at: String
        let app: String
        let raw: String
        let cleaned: String
        let audioSeconds: Double
        let decodeMs: Int
    }

    private static let clock: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func record(app: String, raw: String, cleaned: String, audioSeconds: Double, decodeMs: Int) {
        let entry = Entry(at: clock.string(from: Date()), app: app, raw: raw, cleaned: cleaned,
                          audioSeconds: (audioSeconds * 100).rounded() / 100, decodeMs: decodeMs)
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.warn("HISTORY write failed: \(error.localizedDescription)")
        }
    }
}
