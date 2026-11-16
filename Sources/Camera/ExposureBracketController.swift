import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

enum ExposureBracketError: Error, LocalizedError, Equatable {
    case hardwareAdjustmentUnsupported
    case exposureSettlingTimedOut
    case deviceDisconnected
    case captureCancelled
    case exposureChangeIgnored
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .hardwareAdjustmentUnsupported:
            return "Hardware exposure adjustment is not supported by the camera."
        case .exposureSettlingTimedOut:
            return "Timed out waiting for exposure settling."
        case .deviceDisconnected:
            return "Camera was disconnected during exposure bracketing."
        case .captureCancelled:
            return "Exposure bracketing was cancelled."
        case .exposureChangeIgnored:
            return "Camera hardware ignored requested exposure changes."
        case let .captureFailed(msg):
            return "Photo capture failed: \(msg)"
        }
    }
}

/// Complete camera configuration snapshot captured prior to exposure bracketing and restored afterward.
struct SavedCameraExposureConfiguration: Equatable {
    let exposureMode: AVCaptureDevice.ExposureMode
    let exposurePointOfInterest: CGPoint?
    let exposureBias: Float
    let focusMode: AVCaptureDevice.FocusMode
    let focusPointOfInterest: CGPoint?
    let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode

    static func snapshot(from device: AVCaptureDevice, capabilities: CameraHardwareExposureCapabilities) -> SavedCameraExposureConfiguration {
        return SavedCameraExposureConfiguration(
            exposureMode: device.exposureMode,
            exposurePointOfInterest: device.isExposurePointOfInterestSupported ? device.exposurePointOfInterest : nil,
            exposureBias: capabilities.currentBias,
            focusMode: device.focusMode,
            focusPointOfInterest: device.isFocusPointOfInterestSupported ? device.focusPointOfInterest : nil,
            whiteBalanceMode: device.whiteBalanceMode
        )
    }
}

/// AVFoundation adapter that bridges a physical AVCaptureDevice into the tested CameraExposureControlling protocol.
final class AVCaptureExposureAdapter: CameraExposureControlling {
    let device: AVCaptureDevice
    let capabilities: CameraHardwareExposureCapabilities
    let savedConfiguration: SavedCameraExposureConfiguration
    let settlingTimeout: TimeInterval
    let pollInterval: TimeInterval
    private let capturePhotoHandler: (Float, @escaping (Result<CapturedExposure, Error>) -> Void) -> Void
    private let workQueue: DispatchQueue

    init(
        device: AVCaptureDevice,
        capabilities: CameraHardwareExposureCapabilities,
        settlingTimeout: TimeInterval = 0.85,
        pollInterval: TimeInterval = 0.025,
        workQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
        capturePhotoHandler: @escaping (Float, @escaping (Result<CapturedExposure, Error>) -> Void) -> Void
    ) {
        self.device = device
        self.capabilities = capabilities
        self.savedConfiguration = SavedCameraExposureConfiguration.snapshot(from: device, capabilities: capabilities)
        self.settlingTimeout = settlingTimeout
        self.pollInterval = pollInterval
        self.workQueue = workQueue
        self.capturePhotoHandler = capturePhotoHandler
    }

    func setExposureBias(_ bias: Float, completion: @escaping (Result<Void, Error>) -> Void) {
        guard device.isConnected else {
            completion(.failure(ExposureBracketError.deviceDisconnected))
            return
        }
        guard capabilities.supportsHardwareAdjustment, capabilities.isHardwareBracketingSupported else {
            completion(.failure(ExposureBracketError.hardwareAdjustmentUnsupported))
            return
        }

        let clampedBias = min(max(bias, capabilities.minBias), capabilities.maxBias)
        let stateLock = NSLock()
        var didComplete = false
        var hardwareCallbackFired = false

        func finishOnce(_ result: Result<Void, Error>) {
            stateLock.lock()
            if didComplete {
                stateLock.unlock()
                return
            }
            didComplete = true
            stateLock.unlock()
            completion(result)
        }

        var applyError: NSError?
        var innerError: NSError?
        var lockFailed = false
        let startedAt = Date().timeIntervalSince1970

        let applied = BondScanTry({
            do {
                try self.device.lockForConfiguration()
                defer { self.device.unlockForConfiguration() }
                if self.device.isExposureModeSupported(.continuousAutoExposure),
                   self.device.exposureMode != .continuousAutoExposure
                {
                    self.device.exposureMode = .continuousAutoExposure
                }
                let ok = BondScanSetExposureTargetBias(self.device, clampedBias, { _ in
                    stateLock.lock()
                    hardwareCallbackFired = true
                    stateLock.unlock()
                }, &innerError)
                if !ok {
                    lockFailed = true
                }
            } catch {
                lockFailed = true
            }
        }, &applyError)

        if !applied || lockFailed || applyError != nil || innerError != nil {
            finishOnce(.failure(ExposureBracketError.hardwareAdjustmentUnsupported))
            return
        }

        func pollUntilSettled() {
            stateLock.lock()
            let alreadyDone = didComplete
            let callbackDone = hardwareCallbackFired
            stateLock.unlock()
            if alreadyDone {
                return
            }
            guard device.isConnected else {
                finishOnce(.failure(ExposureBracketError.deviceDisconnected))
                return
            }
            let elapsed = Date().timeIntervalSince1970 - startedAt
            let isAdjusting = device.isAdjustingExposure
            if callbackDone || elapsed >= 0.05, !isAdjusting {
                finishOnce(.success(()))
                return
            }
            if elapsed >= settlingTimeout {
                finishOnce(.failure(ExposureBracketError.exposureSettlingTimedOut))
                return
            }
            workQueue.asyncAfter(deadline: .now() + pollInterval) {
                pollUntilSettled()
            }
        }

        workQueue.asyncAfter(deadline: .now() + pollInterval) {
            pollUntilSettled()
        }
    }

    func restoreExposure(completion: @escaping () -> Void) {
        let config = savedConfiguration
        var err: NSError?
        _ = BondScanTry({
            guard self.device.isConnected else { return }
            do {
                try self.device.lockForConfiguration()
                defer { self.device.unlockForConfiguration() }
                if let expPoint = config.exposurePointOfInterest, self.device.isExposurePointOfInterestSupported {
                    self.device.exposurePointOfInterest = expPoint
                }
                if self.device.isExposureModeSupported(config.exposureMode) {
                    self.device.exposureMode = config.exposureMode
                } else if self.device.isExposureModeSupported(.continuousAutoExposure) {
                    self.device.exposureMode = .continuousAutoExposure
                }
                if self.capabilities.supportsHardwareAdjustment {
                    var biasErr: NSError?
                    _ = BondScanSetExposureTargetBias(self.device, config.exposureBias, nil, &biasErr)
                }
                if let focusPoint = config.focusPointOfInterest, self.device.isFocusPointOfInterestSupported {
                    self.device.focusPointOfInterest = focusPoint
                }
                if self.device.isFocusModeSupported(config.focusMode) {
                    self.device.focusMode = config.focusMode
                }
                if self.device.isWhiteBalanceModeSupported(config.whiteBalanceMode) {
                    self.device.whiteBalanceMode = config.whiteBalanceMode
                }
            } catch {
                ScanLog.shared.write("could not restore previous camera exposure configuration")
            }
        }, &err)
        completion()
    }

    func captureStillPhoto(for bias: Float, completion: @escaping (Result<CapturedExposure, Error>) -> Void) {
        guard device.isConnected else {
            completion(.failure(ExposureBracketError.deviceDisconnected))
            return
        }
        capturePhotoHandler(bias, completion)
    }
}

/// Orchestrates sequential exposure bracketing across capable camera controllers.
final class ExposureBracketController {
    let timeoutSeconds: TimeInterval
    let minLuminanceDifference: Float
    private let timeoutQueue = DispatchQueue(label: "bondscanner.exposureBracket.timeout", qos: .userInitiated)

    init(timeoutSeconds: TimeInterval = 1.0, minLuminanceDifference: Float = 0.02) {
        self.timeoutSeconds = timeoutSeconds
        self.minLuminanceDifference = minLuminanceDifference
    }

    private func runWithTimeout<T>(
        timeoutError: Error,
        operation: (@escaping (Result<T, Error>) -> Void) -> Void,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let lock = NSLock()
        var finished = false

        let timeoutWork = DispatchWorkItem {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            completion(.failure(timeoutError))
        }

        timeoutQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        operation { result in
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            timeoutWork.cancel()
            completion(result)
        }
    }

    /// Executes the bracket plan on the given camera controller.
    func executeBracket(
        transaction: CaptureTransaction,
        camera: CameraExposureControlling,
        completion: @escaping (Result<[CapturedExposure], Error>) -> Void
    ) {
        if transaction.isCancelled {
            camera.restoreExposure {
                completion(.failure(ExposureBracketError.captureCancelled))
            }
            return
        }

        let targets = transaction.targetBiases
        guard targets.count > 1, camera.capabilities.isHardwareBracketingSupported, camera.capabilities.supportsHardwareAdjustment else {
            runWithTimeout(
                timeoutError: ExposureBracketError.exposureSettlingTimedOut,
                operation: { done in
                    camera.captureStillPhoto(for: 0.0, completion: done)
                },
                completion: { result in
                    if transaction.isCancelled {
                        camera.restoreExposure {
                            completion(.failure(ExposureBracketError.captureCancelled))
                        }
                        return
                    }
                    switch result {
                    case let .success(exposure):
                        transaction.addExposure(exposure)
                        completion(.success([exposure]))
                    case let .failure(error):
                        completion(.failure(error))
                    }
                }
            )
            return
        }

        var results: [CapturedExposure] = []
        var currentIndex = 0

        func finishWithRestore(errorIfNoBaseline: Error) {
            camera.restoreExposure {
                if transaction.isCancelled {
                    completion(.failure(ExposureBracketError.captureCancelled))
                    return
                }
                let baselineOnly = results.filter(\.isBaseline)
                if !baselineOnly.isEmpty {
                    transaction.replaceExposures(baselineOnly)
                    completion(.success(baselineOnly))
                } else {
                    completion(.failure(errorIfNoBaseline))
                }
            }
        }

        func stepNext() {
            if transaction.isCancelled {
                camera.restoreExposure {
                    completion(.failure(ExposureBracketError.captureCancelled))
                }
                return
            }

            guard currentIndex < targets.count else {
                camera.restoreExposure {
                    if transaction.isCancelled {
                        completion(.failure(ExposureBracketError.captureCancelled))
                        return
                    }
                    let accepted = transaction.acceptedDistinctExposures(minDifference: self.minLuminanceDifference)
                    transaction.replaceExposures(accepted)
                    completion(.success(accepted.isEmpty ? results : accepted))
                }
                return
            }

            let bias = targets[currentIndex]
            currentIndex += 1

            if bias == 0.0 {
                runWithTimeout(
                    timeoutError: ExposureBracketError.exposureSettlingTimedOut,
                    operation: { done in
                        camera.captureStillPhoto(for: 0.0, completion: done)
                    },
                    completion: { result in
                        if transaction.isCancelled {
                            camera.restoreExposure {
                                completion(.failure(ExposureBracketError.captureCancelled))
                            }
                            return
                        }
                        switch result {
                        case let .success(exp):
                            results.append(exp)
                            transaction.addExposure(exp)
                            stepNext()
                        case let .failure(err):
                            finishWithRestore(errorIfNoBaseline: err)
                        }
                    }
                )
            } else {
                runWithTimeout(
                    timeoutError: ExposureBracketError.exposureSettlingTimedOut,
                    operation: { done in
                        camera.setExposureBias(bias, completion: done)
                    },
                    completion: { biasResult in
                        if transaction.isCancelled {
                            camera.restoreExposure {
                                completion(.failure(ExposureBracketError.captureCancelled))
                            }
                            return
                        }
                        switch biasResult {
                        case .success:
                            self.runWithTimeout(
                                timeoutError: ExposureBracketError.exposureSettlingTimedOut,
                                operation: { done in
                                    camera.captureStillPhoto(for: bias, completion: done)
                                },
                                completion: { photoResult in
                                    if transaction.isCancelled {
                                        camera.restoreExposure {
                                            completion(.failure(ExposureBracketError.captureCancelled))
                                        }
                                        return
                                    }
                                    switch photoResult {
                                    case let .success(exp):
                                        results.append(exp)
                                        transaction.addExposure(exp)
                                        stepNext()
                                    case let .failure(err):
                                        finishWithRestore(errorIfNoBaseline: err)
                                    }
                                }
                            )
                        case let .failure(err):
                            finishWithRestore(errorIfNoBaseline: err)
                        }
                    }
                )
            }
        }

        stepNext()
    }
}
