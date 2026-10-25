// Small custom views drawn with plain Cocoa drawing: one view for the whole keyboard instead of 81 controls.
#import <Cocoa/Cocoa.h>
#include "../core/f75_core.h"

NSColor *F75Hex(unsigned rgb);
NSColor *F75HexString(NSString *hex);

@interface F75FlippedView : NSView
@end

// Rounded panel; colors applied in updateLayer so AppKit keeps them across appearance changes.
@interface F75Panel : NSView
@property (strong) NSColor *fill, *border;
@property CGFloat radius, borderWidth;
+ (instancetype)panelWithFill:(unsigned)fill border:(unsigned)border radius:(CGFloat)radius;
@end

// Mode A turns the yellow button into "hide": returning YES from the handler skips the Dock minimize.
@interface F75Window : NSWindow
@property (copy) BOOL (^miniaturizeHandler)(void);
@end

@interface F75KeyboardView : NSView
@property (assign) const f75_profile *profile;
@property (strong) NSMutableIndexSet *selection;
@property (copy) void (^keyClicked)(int index, BOOL toggle);
@end

@interface F75Swatch : NSView
@property unsigned color;
@property (nonatomic) BOOL active;
@property (copy) void (^clicked)(unsigned color);
@end

// Focusable box that reports raw key down/up (including modifiers) while recording a macro.
@interface F75KeyCaptureView : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic) BOOL recording;
@property (copy) void (^keyEvent)(unsigned short keyCode, BOOL down);
@end
