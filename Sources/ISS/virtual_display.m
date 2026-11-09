#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "include/ISS.h"

// Private signatures verified against Stengo/DeskPad's CGVirtualDisplayPrivate.h.
@interface NSObject (ISSVirtualDisplayAPI)
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)rate;
- (BOOL)applySettings:(id)settings;
- (CGDirectDisplayID)displayID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setName:(NSString *)name;
- (void)setMaxPixelsWide:(unsigned int)width;
- (void)setMaxPixelsHigh:(unsigned int)height;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setSerialNum:(unsigned int)serial;
- (void)setVendorID:(unsigned int)vendor;
- (void)setProductID:(unsigned int)product;
- (void)setHiDPI:(unsigned int)enabled;
- (void)setModes:(NSArray *)modes;
@end

// Owned for the process lifetime. Call only on the main thread.
static id stagingDisplay;
uint32_t iss_ensure_virtual_display(void) {
    if (stagingDisplay) return [stagingDisplay displayID];
    @try {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!descriptorClass || !displayClass || !modeClass || !settingsClass) return 0;
        id descriptor = [[descriptorClass alloc] init];
        [descriptor setDispatchQueue:dispatch_get_main_queue()];
        [descriptor setName:@"Cubicle Staging (Experimental)"];
        [descriptor setMaxPixelsWide:1280];
        [descriptor setMaxPixelsHigh:720];
        [descriptor setSizeInMillimeters:CGSizeMake(530, 300)];
        [descriptor setVendorID:0x4355];
        [descriptor setProductID:1];
        [descriptor setSerialNum:1];
        id display = [[displayClass alloc] initWithDescriptor:descriptor];
        id mode = [[modeClass alloc] initWithWidth:1280 height:720 refreshRate:60];
        id settings = [[settingsClass alloc] init];
        [settings setHiDPI:0];
        [settings setModes:@[mode]];
        BOOL applied = [display applySettings:settings];
        if (!applied || ![display displayID]) { return 0; }
        stagingDisplay = display;
        return [display displayID];
    } @catch (NSException *exception) {
        NSLog(@"Cubicle virtual display unavailable: %@", exception.reason);
        return 0;
    }
}

uint32_t iss_virtual_display_id(void) {
    return stagingDisplay ? [stagingDisplay displayID] : 0;
}
void iss_remove_virtual_display(void) {
    stagingDisplay = nil;
}
