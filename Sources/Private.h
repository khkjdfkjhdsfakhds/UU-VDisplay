#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int vendorID, productID, serialNum;
@property (nonatomic, strong) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width, height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// IOAVService (Apple Silicon DDC)
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef _Nullable CF_RETURNS_RETAINED IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
NS_ASSUME_NONNULL_END
