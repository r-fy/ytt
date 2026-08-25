import Foundation

// Timestamped lines to ~/Library/Logs/YTT.log and stderr.
enum Log {
    private static let startedAt = Date()
    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/YTT.log")
    private static let queue = DispatchQueue(label: "ytt.log")
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ message: String) { write(message) }
    static func warn(_ message: String) { write("WARN " + message) }

    private static func write(_ message: String) {
        let line = String(format: "[%8.3fs] ", Date().timeIntervalSince(startedAt)) + message + "\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
