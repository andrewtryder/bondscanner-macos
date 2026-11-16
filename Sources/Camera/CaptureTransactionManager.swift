import CoreGraphics
import Foundation

/// Represents a single captured photo within an exposure sequence.
struct CapturedExposure {
    let biasEV: Float
    let image: CGImage
    let jpegBytes: Data?
    let capturedAt: TimeInterval
    let meanLuminance: Float
    let sharpnessScore: Float
    let isBaseline: Bool
    var relativePath: String = ""

    init(
        biasEV: Float,
        image: CGImage,
        jpegBytes: Data?,
        capturedAt: TimeInterval = Date().timeIntervalSince1970,
        meanLuminance: Float,
        sharpnessScore: Float,
        isBaseline: Bool,
        relativePath: String = ""
    ) {
        self.biasEV = biasEV
        self.image = image
        self.jpegBytes = jpegBytes
        self.capturedAt = capturedAt
        self.meanLuminance = meanLuminance
        self.sharpnessScore = sharpnessScore
        self.isBaseline = isBaseline
        self.relativePath = relativePath
    }
}

/// A coordinated capture transaction that safely manages single or multi-exposure capture.
final class CaptureTransaction {
    let id: UUID
    let requestedAt: TimeInterval
    let automatic: Bool
    let targetBiases: [Float]
    let deviceUniqueID: String?
    let sessionGeneration: UInt64
    private let lock = NSLock()
    private var _capturedExposures: [CapturedExposure] = []
    private var _isCancelled: Bool = false

    var capturedExposures: [CapturedExposure] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedExposures
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    init(
        id: UUID = UUID(),
        requestedAt: TimeInterval = Date().timeIntervalSince1970,
        automatic: Bool,
        targetBiases: [Float],
        deviceUniqueID: String? = nil,
        sessionGeneration: UInt64 = 0
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.automatic = automatic
        self.targetBiases = targetBiases.isEmpty ? [0.0] : targetBiases
        self.deviceUniqueID = deviceUniqueID
        self.sessionGeneration = sessionGeneration
    }

    func addExposure(_ exposure: CapturedExposure) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isCancelled else { return }
        _capturedExposures.append(exposure)
    }

    func replaceExposures(_ exposures: [CapturedExposure]) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isCancelled else { return }
        _capturedExposures = exposures
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = true
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled || _capturedExposures.count >= targetBiases.count
    }

    var baselineExposure: CapturedExposure? {
        lock.lock()
        defer { lock.unlock() }
        return _capturedExposures.first(where: \.isBaseline) ?? _capturedExposures.first
    }

    /// Returns only the exposures that exhibit genuinely distinct luminance compared to the baseline.
    /// If no bracketed exposure differs from the baseline by at least `minDifference`, returns only the baseline.
    func acceptedDistinctExposures(minDifference: Float = 0.02) -> [CapturedExposure] {
        lock.lock()
        let snapshot = _capturedExposures
        lock.unlock()
        guard let baseline = snapshot.first(where: \.isBaseline) ?? snapshot.first else {
            return []
        }
        guard snapshot.count >= 2 else {
            return [baseline]
        }
        var accepted: [CapturedExposure] = [baseline]
        for exp in snapshot where !exp.isBaseline {
            if abs(exp.meanLuminance - baseline.meanLuminance) >= minDifference {
                accepted.append(exp)
            }
        }
        return accepted
    }

    /// Verifies whether the captured exposures demonstrate genuinely different exposure levels.
    /// Returns true if multiple exposures exist and their mean luminances differ by at least minDifference.
    func haveGenuinelyDifferentExposures(minDifference: Float = 0.025) -> Bool {
        let exposures = capturedExposures
        guard exposures.count >= 2 else { return false }
        let luminances = exposures.map(\.meanLuminance)
        guard let minL = luminances.min(), let maxL = luminances.max() else { return false }
        return (maxL - minL) >= minDifference
    }
}

/// Protocol for injecting camera capture and exposure adjustment (used by real hardware and tests).
protocol CameraExposureControlling: AnyObject {
    var capabilities: CameraHardwareExposureCapabilities { get }
    func setExposureBias(_ bias: Float, completion: @escaping (Result<Void, Error>) -> Void)
    func restoreExposure(completion: @escaping () -> Void)
    func captureStillPhoto(for bias: Float, completion: @escaping (Result<CapturedExposure, Error>) -> Void)
}

/// State machine for coordinating capture transactions.
final class CaptureTransactionCoordinator {
    enum State: Equatable {
        case idle
        case active(transactionId: UUID)
    }

    private let lock = NSLock()
    private var _state: State = .idle
    private var currentTransaction: CaptureTransaction?

    init() {}

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .active = _state {
            return true
        }
        return false
    }

    var activeTransaction: CaptureTransaction? {
        lock.lock()
        defer { lock.unlock() }
        return currentTransaction
    }

    func isTransactionActive(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case let .active(activeId) = _state,
              activeId == id,
              let current = currentTransaction,
              !current.isCancelled
        else {
            return false
        }
        return true
    }

    func startTransaction(
        automatic: Bool,
        targetBiases: [Float],
        deviceUniqueID: String? = nil,
        sessionGeneration: UInt64 = 0
    ) -> CaptureTransaction? {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = _state else {
            return nil
        }
        let transaction = CaptureTransaction(
            automatic: automatic,
            targetBiases: targetBiases,
            deviceUniqueID: deviceUniqueID,
            sessionGeneration: sessionGeneration
        )
        _state = .active(transactionId: transaction.id)
        currentTransaction = transaction
        return transaction
    }

    func finishTransaction(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if case let .active(activeId) = _state, activeId == id {
            _state = .idle
            currentTransaction = nil
        }
    }

    func cancelActiveTransaction() -> CaptureTransaction? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .active(activeId) = _state, let current = currentTransaction, current.id == activeId else {
            return nil
        }
        current.cancel()
        _state = .idle
        currentTransaction = nil
        return current
    }
}
