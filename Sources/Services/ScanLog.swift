import Foundation

// Log only operational telemetry. No OCR text, names, tax IDs, or serial numbers.
final class ScanLog {
    static let shared = ScanLog()
    private let lock = NSLock()

    func write(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: debugURL.path) {
            _ = FileManager.default.createFile(atPath: debugURL.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: debugURL.path) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        if let data = "[\(timestamp)] \(event)\n".data(using: .utf8) { handle.write(data) }
    }
}
