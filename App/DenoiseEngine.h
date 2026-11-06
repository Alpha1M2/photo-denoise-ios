#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class CIImage;
NS_ASSUME_NONNULL_BEGIN
@interface DenoiseEngine : NSObject
@property(atomic) BOOL cancelled;
@property(atomic) CGRect requestedPreviewRegion;
@property(atomic) CGRect processedRegion;
@property(atomic) CGSize sourceSize;
@property(atomic) NSInteger workUnits;
@property(atomic) NSInteger fullWorkUnits;
+ (BOOL)prepareImageBuffer:(NSURL *)source destination:(NSURL *)destination linear:(BOOL)linear error:(NSError **)error;
+ (BOOL)prepareCIImage:(CIImage *)image destination:(NSURL *)destination linear:(BOOL)linear error:(NSError **)error NS_SWIFT_NAME(prepareCIImage(_:destination:linear:));
@property(atomic) BOOL useLocalLinearModel;
+ (BOOL)hasLocalLinearModel;
+ (nullable NSDictionary<NSString *, id> *)rawMetadata:(NSURL *)source;
+ (nullable CIImage *)rawLinearImage:(NSURL *)source error:(NSError **)error NS_SWIFT_NAME(rawLinearImage(_:));
@property(atomic) BOOL accelerate;
@property(atomic,copy) NSString *backendName;
+ (BOOL)renderLinearRaw:(NSURL *)source destination:(NSURL *)destination error:(NSError **)error;
+ (BOOL)writeSmokeRaw:(NSURL *)url;
+ (NSString *)testLinearFixture;
+ (nullable UIImage *)linearBufferPreview:(NSURL *)url;
+ (nullable UIImage *)rawPreview:(NSURL *)url;
// Each invocation is serial. File results use a fresh destination; originals never overwritten.
- (nullable NSURL *)process:(NSURL *)source destination:(NSURL *)destination
                  strength:(float)strength raw:(BOOL)raw preview:(BOOL)preview center:(CGPoint)center
                  progress:(void (^)(double))progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
