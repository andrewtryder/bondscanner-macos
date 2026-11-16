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
    private(set) var capturedExposures: [CapturedExposure] = []
    private(set) var isCancelled: Bool = false

    init(
        id: UUID = UUID(),
        requestedAt: TimeInterval = Date().timeIntervalSince1970,
        automatic: Bool,
        targetBiases: [Float]
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.automatic = automatic
        self.targetBiases = targetBiases.isEmpty ? [0.0] : targetBiases
    }

    func addExposure(_ exposure: CapturedExposure) {
        guard !isCancelled else { return }
        capturedExposures.append(exposure)
    }

    func cancel() {
        isCancelled = true
    }

    var isComplete: Bool {
        isCancelled || capturedExposures.count >= targetBiases.count
    }

    var baselineExposure: CapturedExposure? {
        capturedExposures.first(where: \.isBaseline) ?? capturedExposures.first
    }

    /// Verifies whether the captured exposures demonstrate genuinely different exposure levels.
    /// Returns true if multiple exposures exist and their mean luminances differ by at least minDifference.
    func haveGenuinelyDifferentExposures(minDifference: Float = 0.025) -> Bool {
        guard capturedExposures.count >= 2 else { return false }
        let luminances = capturedExposures.map(\.meanLuminance)
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

    private(set) var state: State = .idle
    private var currentTransaction: CaptureTransaction?

    init() {}

    var isBusy: Bool {
        if case .active = state {
            return true
        }
        return false
    }

    func startTransaction(
        automatic: Bool,
        targetBiases: [Float]
    ) -> CaptureTransaction? {
        guard case .idle = state else {
            return nil
        }
        let transaction = CaptureTransaction(automatic: automatic, targetBiases: targetBiases)
        state = .active(transactionId: transaction.id)
        currentTransaction = transaction
        return transaction
    }

    func finishTransaction(id: UUID) {
        if case let .active(activeId) = state, activeId == id {
            state = .idle
            currentTransaction = nil
        }
    }

    func cancelActiveTransaction() -> CaptureTransaction? {
        guard case let .active(activeId) = state, let current = currentTransaction, current.id == activeId else {
            return nil
        }
        current.cancel()
        state = .idle
        currentTransaction = nil
        return current
    }
}
