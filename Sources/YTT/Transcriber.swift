import Foundation

// The engine boundary. Swapping the websocket server for the C API later
// means one new type conforming to this, nothing else changes.
protocol Transcriber: AnyObject {
    var isReady: Bool { get }
    func start()
    func stop()
    func transcribe(samples: [Float], completion: @escaping (Result<String, Error>) -> Void)
}
