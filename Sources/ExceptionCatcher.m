#import "ExceptionCatcher.h"

@interface NSObject (BondScanExposureTargetBiasSelectors)
- (float)minExposureTargetBias;
- (float)maxExposureTargetBias;
- (float)exposureTargetBias;
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^ _Nullable)(CMTime syncTime))handler;
@end

BOOL BondScanTry(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        if (block) { block(); }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Objective-C exception";
            if (exception.name) { info[@"exceptionName"] = exception.name; }
            if (exception.reason) { info[@"exceptionReason"] = exception.reason; }
            *error = [NSError errorWithDomain:@"BondScanner.AVCapture" code:1 userInfo:info];
        }
        return NO;
    }
}

BOOL BondScanGetExposureBiasCapabilities(AVCaptureDevice * _Nonnull device,
                                         float * _Nonnull minBias,
                                         float * _Nonnull maxBias,
                                         float * _Nonnull currentBias) {
    *minBias = 0.0f;
    *maxBias = 0.0f;
    *currentBias = 0.0f;
    @try {
        if (![device respondsToSelector:@selector(setExposureTargetBias:completionHandler:)]) {
            return NO;
        }
        BOOL hasRange = NO;
        if (@available(macOS 15.0, *)) {
            AVExposureBiasRange *recommended = device.activeFormat.systemRecommendedExposureBiasRange;
            if (recommended != nil) {
                *minBias = recommended.minExposureBias;
                *maxBias = recommended.maxExposureBias;
                hasRange = (*maxBias > *minBias);
            }
        }
        if (!hasRange &&
            [device respondsToSelector:@selector(minExposureTargetBias)] &&
            [device respondsToSelector:@selector(maxExposureTargetBias)]) {
            *minBias = [(NSObject *)device minExposureTargetBias];
            *maxBias = [(NSObject *)device maxExposureTargetBias];
            hasRange = (*maxBias > *minBias);
        }
        if ([device respondsToSelector:@selector(exposureTargetBias)]) {
            *currentBias = [(NSObject *)device exposureTargetBias];
        }
        return hasRange && ((*maxBias - *minBias) >= 0.2f);
    } @catch (NSException *exception) {
        *minBias = 0.0f;
        *maxBias = 0.0f;
        *currentBias = 0.0f;
        return NO;
    }
}

BOOL BondScanSetExposureTargetBias(AVCaptureDevice * _Nonnull device,
                                   float bias,
                                   void (^ _Nullable completionHandler)(CMTime syncTime),
                                   NSError * _Nullable * _Nullable error) {
    if (![device respondsToSelector:@selector(setExposureTargetBias:completionHandler:)]) {
        if (error) {
            *error = [NSError errorWithDomain:@"BondScanner.AVCapture"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Exposure target bias selector unsupported"}];
        }
        return NO;
    }
    return BondScanTry(^{
        [(NSObject *)device setExposureTargetBias:bias completionHandler:completionHandler];
    }, error);
}
