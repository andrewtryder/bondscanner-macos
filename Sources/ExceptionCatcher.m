#import "ExceptionCatcher.h"

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
