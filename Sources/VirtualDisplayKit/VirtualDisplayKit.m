#import "include/VirtualDisplayKit.h"

// Declared here rather than imported: these classes ship inside CoreGraphics
// but Apple publishes no header for them.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) dispatch_queue_t queue;
@property (copy) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property unsigned int serialNum;
@property unsigned int productID;
@property unsigned int vendorID;
@property (copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray *modes;
@property unsigned int hiDPI;
@property unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) unsigned int displayID;
@end

@implementation ChinchillaVirtualDisplay {
    CGVirtualDisplay *_display;
    CGDirectDisplayID _displayID;
}

- (instancetype)initWithName:(NSString *)name
                       width:(uint32_t)width
                      height:(uint32_t)height
                 refreshRate:(double)refreshRate {
    self = [super init];
    if (!self) { return nil; }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    // If a future macOS drops these, fail cleanly instead of crashing: the
    // caller falls back to mirroring the real screen.
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) { return self; }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.queue = dispatch_queue_create("chinchilla.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    descriptor.name = name;
    // Size it like a real monitor at roughly 110 ppi. An implausible panel is
    // rejected without a word.
    descriptor.sizeInMillimeters = CGSizeMake(width / 110.0 * 25.4, height / 110.0 * 25.4);
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.serialNum = 1;              // zero is silently refused
    descriptor.productID = 0x1234;
    descriptor.vendorID = 0x3456;
    descriptor.terminationHandler = ^(id a, id b) {};

    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display) { return self; }

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width
                                                          height:height
                                                     refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = 0;
    settings.rotation = 0;
    if (![_display applySettings:settings]) { _display = nil; return self; }

    // applySettings returns before the display exists; wait for it to show up
    // so the caller can capture it immediately.
    CGDirectDisplayID candidate = (CGDirectDisplayID)[_display displayID];
    for (int attempt = 0; attempt < 40; attempt++) {
        uint32_t count = 0;
        CGGetActiveDisplayList(0, NULL, &count);
        CGDirectDisplayID ids[16];
        uint32_t filled = 0;
        CGGetActiveDisplayList(16, ids, &filled);
        for (uint32_t i = 0; i < filled; i++) {
            if (ids[i] == candidate) {
                _displayID = candidate;
                return self;
            }
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    _display = nil;                         // never came up; don't pretend
    return self;
}

- (CGDirectDisplayID)displayID { return _displayID; }
- (BOOL)isActive { return _displayID != 0; }

- (void)invalidate {
    _display = nil;                         // releasing it removes the display
    _displayID = 0;
}

- (void)dealloc { [self invalidate]; }

@end
