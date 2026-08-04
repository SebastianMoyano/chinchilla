#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A real second display, created in software.
///
/// macOS has no public API for this, but CoreGraphics carries the machinery
/// that AirPlay and Sidecar are built on and it is reachable. This is the
/// same route the display utilities on the App Store take; it needs no
/// driver, no system extension and no reboot — the display appears in
/// Displays preferences and macOS arranges windows onto it like any other.
///
/// Three details decide whether it works, and all three fail *silently* — the
/// call returns success and hands back an ID, and then no display ever
/// arrives. Measured, not guessed:
///   • the physical size must be plausible for a monitor (a 1.6 m panel is
///     rejected; ~600 x 340 mm is not),
///   • the serial number must be non-zero,
///   • the process needs a GUI session — an NSApplication. A plain
///     command-line tool gets the same cheerful success and no display,
///     which is why this can't be covered by `swift test`.
@interface ChinchillaVirtualDisplay : NSObject

/// Creates the display and waits briefly for macOS to bring it up.
/// `displayID` is 0 when it didn't appear.
- (instancetype)initWithName:(NSString *)name
                       width:(uint32_t)width
                      height:(uint32_t)height
                 refreshRate:(double)refreshRate;

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// Removes the display. Windows on it move back, exactly as unplugging a
/// monitor. Called automatically on dealloc.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
