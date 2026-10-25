#import "F75Views.h"

NSColor *F75Hex(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

NSColor *F75HexString(NSString *hex) {
    unsigned value = 0;
    [[NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]] scanHexInt:&value];
    return F75Hex(value);
}

@implementation F75FlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation F75Panel
+ (instancetype)panelWithFill:(unsigned)fill border:(unsigned)border radius:(CGFloat)radius {
    F75Panel *panel = [F75Panel new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.wantsLayer = YES;
    panel.fill = F75Hex(fill); panel.border = F75Hex(border); panel.radius = radius; panel.borderWidth = border == fill ? 0 : 1;
    return panel;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.backgroundColor = self.fill.CGColor;
    self.layer.borderColor = self.border.CGColor;
    self.layer.borderWidth = self.borderWidth;
    self.layer.cornerRadius = self.radius;
}
@end

@implementation F75Window
- (void)miniaturize:(id)sender {
    if (self.miniaturizeHandler && self.miniaturizeHandler()) return;
    [super miniaturize:sender];
}
@end

#pragma mark Keyboard

// Layout coordinates come from the vendor layout (600 x 267); the view scales them to its width.
static const CGFloat LayoutWidth = 600, LayoutHeight = 267;

@implementation F75KeyboardView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (CGFloat)scale { return self.bounds.size.width / LayoutWidth; }

- (NSRect)rectForKey:(const f75_key *)k {
    CGFloat s = [self scale];
    return NSMakeRect(k->x * s, k->y * s, k->w * s, k->h * s);
}

- (void)drawRect:(NSRect)dirty {
    CGFloat s = [self scale];
    [F75Hex(0x101722) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    for (int i = 0; i < F75_KEY_COUNT; i++) {
        const f75_key *k = &f75_keys[i];
        NSRect r = NSInsetRect([self rectForKey:k], 1, 1);
        if (!NSIntersectsRect(r, dirty)) continue;
        int v = self.profile ? self.profile->colors[k->index] : 0, br = self.profile ? self.profile->brightness : 100;
        int red = ((v >> 16) & 255) * br / 100, green = ((v >> 8) & 255) * br / 100, blue = (v & 255) * br / 100;
        BOOL unlit = v == 0 || br == 0, selected = [self.selection containsIndex:(NSUInteger)k->index];
        int luminance = (red * 299 + green * 587 + blue * 114) / 1000;
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4 * s yRadius:4 * s];
        [(unlit ? F75Hex(0x232D3A) : F75Hex((unsigned)((red << 16) | (green << 8) | blue))) setFill];
        [path fill];
        path.lineWidth = selected ? 3 : 1;
        [(selected ? NSColor.whiteColor : F75Hex(0x465468)) setStroke];
        [path stroke];
        NSString *name = [NSString stringWithUTF8String:k->name];
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:(name.length > 5 ? 7 : 9) * s],
                                     NSForegroundColorAttributeName: F75Hex(unlit || luminance < 145 ? 0xF3F7FC : 0x10202A),
                                     NSParagraphStyleAttributeName: center};
        NSSize size = [name sizeWithAttributes:attributes];
        [name drawInRect:NSMakeRect(r.origin.x, NSMidY(r) - size.height / 2, r.size.width, size.height) withAttributes:attributes];
    }
    // Side light bar (no known independent control) and the knob, for orientation only.
    [F75Hex(0xBDC8D2) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(531 * s, 70 * s, 7 * s, 125 * s) xRadius:3 * s yRadius:3 * s] fill];
    NSBezierPath *knob = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(539 * s, 20 * s, 39 * s, 39 * s)];
    [F75Hex(0x343D48) setFill];
    [knob fill];
    knob.lineWidth = 3;
    [F75Hex(0x526172) setStroke];
    [knob stroke];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (int i = 0; i < F75_KEY_COUNT; i++) {
        if (!NSPointInRect(p, [self rectForKey:&f75_keys[i]])) continue;
        BOOL toggle = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift)) != 0;
        if (self.keyClicked) self.keyClicked(f75_keys[i].index, toggle);
        return;
    }
}
@end

#pragma mark Swatch

@implementation F75Swatch
- (NSSize)intrinsicContentSize { return NSMakeSize(40, 40); }
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:8 yRadius:8];
    [F75Hex(self.color) setFill];
    [path fill];
    path.lineWidth = self.active ? 4 : 2;
    [(self.active ? NSColor.whiteColor : F75Hex(0x405064)) setStroke];
    [path stroke];
}
- (void)setActive:(BOOL)active { _active = active; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event { if (self.clicked) self.clicked(self.color); }
@end

#pragma mark Macro capture

@implementation F75KeyCaptureView {
    NSMutableIndexSet *heldModifiers;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }
- (void)setText:(NSString *)text { _text = [text copy]; self.needsDisplay = YES; }
- (void)setRecording:(BOOL)recording { _recording = recording; [heldModifiers removeAllIndexes]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:8 yRadius:8];
    [F75Hex(0x11161F) setFill];
    [path fill];
    [(self.recording ? F75Hex(0xA8F0C9) : F75Hex(0x3B4658)) setStroke];
    [path stroke];
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: F75Hex(0xEEF3FB)};
    [self.text ?: @"" drawInRect:NSInsetRect(self.bounds, 14, 12) withAttributes:attributes];
}
- (void)mouseDown:(NSEvent *)event { [self.window makeFirstResponder:self]; }
- (void)keyDown:(NSEvent *)event {
    if (!self.recording) { [super keyDown:event]; return; }
    if (!event.isARepeat && self.keyEvent) self.keyEvent(event.keyCode, YES);
}
- (void)keyUp:(NSEvent *)event {
    if (!self.recording) { [super keyUp:event]; return; }
    if (self.keyEvent) self.keyEvent(event.keyCode, NO);
}
- (void)flagsChanged:(NSEvent *)event {
    if (!self.recording || !self.keyEvent) { [super flagsChanged:event]; return; }
    if (!heldModifiers) heldModifiers = [NSMutableIndexSet new];
    unsigned short code = event.keyCode;
    if (code == 0x39) { self.keyEvent(code, YES); self.keyEvent(code, NO); return; } // Caps Lock reports only toggles
    BOOL down = ![heldModifiers containsIndex:code];
    if (down) [heldModifiers addIndex:code]; else [heldModifiers removeIndex:code];
    self.keyEvent(code, down);
}
// While recording, Command shortcuts are part of the macro instead of menu commands.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!self.recording || self.window.firstResponder != self) return [super performKeyEquivalent:event];
    if (event.type == NSEventTypeKeyDown) [self keyDown:event];
    return YES;
}
@end
