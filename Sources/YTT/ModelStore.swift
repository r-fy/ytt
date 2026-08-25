import Foundation
import CryptoKit

// Models live in ~/Library/Application Support/YTT/models/<extractDir>/.
// A model counts as installed when its four files exist and a marker
// written after a successful extract is present.
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    struct Model: Decodable {
        let id: String
        let name: String
        let downloadUrl: URL
        let extractDir: String
        let sizeMb: Int
        let sha256: String?
    }
    static let requiredFiles = ["tokens.txt", "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"]
    private struct Manifest: Decodable {
        let `default`: String
        let models: [Model]
    }
    private struct Marker: Codable {
        let id: String
        let archiveSha256: String
        let installedAt: Date
    }

    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/YTT/models")

    let model: Model
    var onProgress: ((Double) -> Void)?
    private var completion: ((Result<URL, Error>) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    override init() {
        let url = Bundle.main.url(forResource: "models", withExtension: "json")!
        let manifest = try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        model = manifest.models.first { $0.id == manifest.default } ?? manifest.models[0]
        super.init()
    }

    var modelDir: URL { ModelStore.root.appendingPathComponent(model.extractDir) }
    private var markerURL: URL { modelDir.appendingPathComponent(".installed.json") }

    private var filesPresent: Bool {
        ModelStore.requiredFiles.allSatisfy { name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelDir.appendingPathComponent(name).path)
            return ((attrs?[.size] as? Int) ?? 0) > 0
        }
        // The encoder is the 650 MB file. Anything under 100 MB is a truncated copy.
        && (((try? FileManager.default.attributesOfItem(atPath: modelDir.appendingPathComponent("encoder.int8.onnx").path))?[.size] as? Int) ?? 0) > 100_000_000
    }

    var isInstalled: Bool {
        filesPresent && FileManager.default.fileExists(atPath: markerURL.path)
    }

    // A copy placed by hand (or by an older version) has no marker. Adopt it
    // only when every file is there and the encoder has a plausible size.
    func adoptExistingIfPresent() {
        guard !FileManager.default.fileExists(atPath: markerURL.path), filesPresent else { return }
        writeMarker(sha: "adopted-from-existing-files")
        Log.info("MODEL adopted existing files in \(modelDir.lastPathComponent)")
    }

    func download(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
        Log.info("MODEL downloading \(model.downloadUrl.lastPathComponent) (~\(model.sizeMb) MB)")
        session.downloadTask(with: model.downloadUrl).resume()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(model.sizeMb) * 1_048_576
        let fraction = min(1, Double(totalBytesWritten) / expected)
        DispatchQueue.main.async { self.onProgress?(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move the temp file before this method returns.
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("ytt-" + model.downloadUrl.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: location, to: archive)
            try install(archive: archive)
            try? FileManager.default.removeItem(at: archive)
            finish(.success(modelDir))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        DispatchQueue.main.async {
            switch result {
            case .success: Log.info("MODEL installed at \(self.modelDir.path)")
            case .failure(let e): Log.warn("MODEL download failed: \(e.localizedDescription)")
            }
            self.completion?(result)
            self.completion = nil
        }
    }

    private func install(archive: URL) throws {
        let sha = try ModelStore.sha256(of: archive)
        if let expected = model.sha256, expected.lowercased() != sha {
            throw NSError(domain: "YTT", code: 4, userInfo: [NSLocalizedDescriptionKey: "downloaded archive does not match the expected checksum"])
        }
        try FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        // Extract into a staging folder and move into place only on success,
        // so a disk-full or interrupted extract never leaves a half model
        // that a later launch could mistake for a good one.
        let staging = ModelStore.root.appendingPathComponent(".staging-\(model.id)")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // System tar handles bzip2, no library needed. bsdtar refuses ".."
        // entries by default, which is the only path-traversal protection
        // here: never add -P.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xjf", archive.path, "-C", staging.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw NSError(domain: "YTT", code: 1, userInfo: [NSLocalizedDescriptionKey: "tar exited \(tar.terminationStatus)"])
        }
        let extracted = staging.appendingPathComponent(model.extractDir)
        guard ModelStore.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: extracted.appendingPathComponent($0).path) }) else {
            throw NSError(domain: "YTT", code: 2, userInfo: [NSLocalizedDescriptionKey: "archive did not contain \(model.extractDir)"])
        }
        try? FileManager.default.removeItem(at: modelDir)
        try FileManager.default.moveItem(at: extracted, to: modelDir)
        writeMarker(sha: sha)
    }

    private func writeMarker(sha: String) {
        let marker = Marker(id: model.id, archiveSha256: sha, installedAt: Date())
        try? JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
