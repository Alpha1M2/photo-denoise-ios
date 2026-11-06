#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface DenoiseEngine : NSObject
@property(atomic) BOOL cancelled;
+ (BOOL)writeSmokeRaw:(NSURL *)url;
// Each invocation is serial. File results use a fresh destination; originals never overwritten.
- (nullable NSURL *)process:(NSURL *)source destination:(NSURL *)destination
                  strength:(float)strength raw:(BOOL)raw preview:(BOOL)preview center:(CGPoint)center
                  progress:(void (^)(double))progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
