import Foundation

/// Log only operational telemetry. No OCR text, names, tax IDs, or serial numbers.
final class ScanLog {
    static let shared = ScanLog()
    private let lock = NSLock()
    var isEnabled: Bool = true
    private var customLogURL: URL?

    func setCustomLogURL(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customLogURL = url
    }

    func resetToDefaults() {
        setCustomLogURL(nil)
    }

    func write(_ event: String) {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let targetURL = customLogURL ?? debugURL
        if customLogURL == nil, isProductionStorageProtected(destination: targetURL) {
            // Guard: in test mode, never create or write to production scan-debug.log
            return
        }
        let dir = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            _ = FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: targetURL.path) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(timestamp)] \(event)\n".utf8)
        handle.write(data)
    }
}
