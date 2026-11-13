#import <Foundation/Foundation.h>

/// Runs the block inside @try/@catch so an Objective-C exception cannot abort the process.
/// Returns YES on success. On exception, returns NO and fills in error if provided.
BOOL BondScanTry(void (NS_NOESCAPE ^_Nonnull block)(void), NSError * _Nullable * _Nullable error);
