import AVFoundation
import CoreGraphics
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

/// Orchestrates sequential exposure bracketing across capable camera controllers.
final class ExposureBracketController {
    let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 1.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Executes the bracket plan on the given camera controller.
    func executeBracket(
        transaction: CaptureTransaction,
        camera: CameraExposureControlling,
        completion: @escaping (Result<[CapturedExposure], Error>) -> Void
    ) {
        let targets = transaction.targetBiases
        guard targets.count > 1, camera.capabilities.isHardwareBracketingSupported, camera.capabilities.supportsHardwareAdjustment else {
            camera.captureStillPhoto(for: 0.0) { result in
                switch result {
                case let .success(exposure):
                    transaction.addExposure(exposure)
                    completion(.success([exposure]))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
            return
        }

        var results: [CapturedExposure] = []
        var currentIndex = 0

        func stepNext() {
            if transaction.isCancelled {
                camera.restoreExposure {
                    completion(.failure(ExposureBracketError.captureCancelled))
                }
                return
            }

            guard currentIndex < targets.count else {
                camera.restoreExposure {
                    if results.count >= 2 {
                        let lums = results.map(\.meanLuminance)
                        let diff = (lums.max() ?? 0) - (lums.min() ?? 0)
                        if diff < 0.02 {
                            let baselineOnly = results.filter(\.isBaseline)
                            completion(.success(baselineOnly.isEmpty ? [results[0]] : baselineOnly))
                            return
                        }
                    }
                    completion(.success(results))
                }
                return
            }

            let bias = targets[currentIndex]
            currentIndex += 1

            if bias == 0.0 {
                camera.captureStillPhoto(for: 0.0) { result in
                    switch result {
                    case let .success(exp):
                        results.append(exp)
                        transaction.addExposure(exp)
                        stepNext()
                    case let .failure(err):
                        camera.restoreExposure {
                            completion(.failure(err))
                        }
                    }
                }
            } else {
                camera.setExposureBias(bias) { biasResult in
                    switch biasResult {
                    case .success:
                        camera.captureStillPhoto(for: bias) { photoResult in
                            switch photoResult {
                            case let .success(exp):
                                results.append(exp)
                                transaction.addExposure(exp)
                                stepNext()
                            case let .failure(err):
                                camera.restoreExposure {
                                    let baselineOnly = results.filter(\.isBaseline)
                                    if !baselineOnly.isEmpty {
                                        completion(.success(baselineOnly))
                                    } else {
                                        completion(.failure(err))
                                    }
                                }
                            }
                        }
                    case let .failure(err):
                        camera.restoreExposure {
                            let baselineOnly = results.filter(\.isBaseline)
                            if !baselineOnly.isEmpty {
                                completion(.success(baselineOnly))
                            } else {
                                completion(.failure(err))
                            }
                        }
                    }
                }
            }
        }

        stepNext()
    }
}
