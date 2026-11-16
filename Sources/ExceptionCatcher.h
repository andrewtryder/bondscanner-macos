#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

/// Runs the block inside @try/@catch so an Objective-C exception cannot abort the process.
/// Returns YES on success. On exception, returns NO and fills in error if provided.
BOOL BondScanTry(void (NS_NOESCAPE ^_Nonnull block)(void), NSError * _Nullable * _Nullable error);

/// Safely queries whether the capture device supports exposure target bias adjustment,
/// populating minBias, maxBias, and currentBias if supported.
BOOL BondScanGetExposureBiasCapabilities(AVCaptureDevice * _Nonnull device,
                                         float * _Nonnull minBias,
                                         float * _Nonnull maxBias,
                                         float * _Nonnull currentBias);

/// Safely sets the exposure target bias on a locked AVCaptureDevice using typed Objective-C messaging
/// inside an @try/@catch block. Invokes completionHandler when the bias has been applied.
BOOL BondScanSetExposureTargetBias(AVCaptureDevice * _Nonnull device,
                                   float bias,
                                   void (^ _Nullable completionHandler)(CMTime syncTime),
                                   NSError * _Nullable * _Nullable error);
