// F75 Studio 1.0 for macOS: AppKit port of App.cs. Same pages, texts, profile file and USB packets as Windows.
// Lightness rules carried over: no polling over the cable, UI tree dropped when hidden or minimized, devices opened
// only per operation, and two explicit exit modes (close for good after saving to the keyboard, or stay in the menu bar).
#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#include <sys/resource.h>
#import "F75HID.h"
#import "F75Views.h"

static const unsigned Bg = 0x0D1118, Panel = 0x171E29, Muted = 0x9DAABD, Accent = 0xA8F0C9, Ink = 0xEEF3FB;

// Keeps a block alive as an AppKit target (targets are not retained by controls).
@interface F75Target : NSObject
@property (copy) void (^block)(id sender);
@end
@implementation F75Target
- (void)fire:(id)sender { if (self.block) self.block(sender); }
@end

@interface F75Studio : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate>
@property BOOL measure;
@end

@implementation F75Studio {
    f75_profile profile;
    NSString *page, *language, *lastStatus, *dataDir, *statePath;
    F75Window *window;
    BOOL uiBuilt, busy, refreshing, rgbOff, dirty, canQuit, quitting, statusStale, suppressSave;
    NSMutableArray *targets;
    NSStackView *nav, *content;
    NSTextField *status, *selectionLabel, *brushLabel, *applyLabel, *connectionText, *batteryText, *deviceStatusText, *hexField, *nameField;
    NSButton *applyButton;
    F75KeyboardView *keyboard;
    NSMutableIndexSet *selected;
    NSMutableDictionary<NSNumber *, F75Swatch *> *swatches;
    NSPopUpButton *effect, *effectBrightness, *speed, *direction, *palette, *latency, *sleepPopup, *trigger;
    NSTextView *macroText;
    F75KeyCaptureView *macroCapture;
    F75Status *snapshot;
    dispatch_queue_t io;
    NSTimer *statusTimer, *saveTimer;
    f75_macro_event events[F75_MAX_MACRO_EVENTS];
    int eventCount;
    BOOL macroRecording;
    CFAbsoluteTime macroClock;
    NSMutableIndexSet *macroHeld;
    NSMutableArray<NSData *> *colorUndo;
    unsigned activeColor;
    NSStatusItem *statusItem;
    NSArray<NSNumber *> *triggerKeys;
}

- (instancetype)init {
    if ((self = [super init])) {
        page = @"light"; language = @"pt-BR"; lastStatus = @"";
        targets = [NSMutableArray new]; selected = [NSMutableIndexSet new]; swatches = [NSMutableDictionary new];
        macroHeld = [NSMutableIndexSet new]; colorUndo = [NSMutableArray new]; activeColor = 0x89F0CE;
        io = dispatch_queue_create("f75.usb", DISPATCH_QUEUE_SERIAL);
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        dataDir = [support stringByAppendingPathComponent:@"F75Studio"];
        statePath = [dataDir stringByAppendingPathComponent:@"session.json"];
        f75_profile_default(&profile);
    }
    return self;
}

- (NSString *)T:(NSString *)pt en:(NSString *)en { return [language isEqualToString:@"en"] ? en : pt; }
#define T(pt, en_) [self T:pt en:en_]

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self loadProfile];
    [self buildMenu];
    window = [[F75Window alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 840)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:YES];
    window.title = @"F75 Studio";
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = F75Hex(Bg);
    window.titlebarAppearsTransparent = YES;
    window.minSize = NSMakeSize(900, 640);
    window.delegate = self;
    __weak F75Studio *weakSelf = self;
    window.miniaturizeHandler = ^BOOL { return [weakSelf miniaturizeToBackground]; };
    [window center];
    [window setFrameAutosaveName:@"F75Studio"];
    [self build];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (profile.keep_in_tray) [self setupStatusItem];
    [F75HID shared].devicesChanged = ^{ [weakSelf devicesChanged]; };
    [[F75HID shared] startWatching];
    [self refresh:NO];
    if (self.measure) [self runMeasurement];
}

- (BOOL)uiVisible { return uiBuilt && window.isVisible && !window.isMiniaturized; }

- (void)devicesChanged {
    if ([self uiVisible]) [self refresh:NO]; else statusStale = YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (busy) { [self setStatus:T(@"Aguarde a operação USB terminar.", @"Wait for the USB operation to finish.")]; return NO; }
    if (profile.keep_in_tray) [self hideToBackground];
    else [NSApp terminate:nil];
    return NO;
}

- (BOOL)miniaturizeToBackground {
    if (!profile.keep_in_tray) return NO;
    [self hideToBackground];
    return YES;
}

// Mode A: only the menu bar icon is left; no Dock icon, no window, no timers, no USB access.
- (void)hideToBackground {
    [self setupStatusItem];
    [window orderOut:nil];
    [self releaseUI];
    [[F75HID shared] stopWatching];
    statusStale = YES;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)showWindow {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (window.isMiniaturized) [window deminiaturize:nil];
    if (!uiBuilt) [self build];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [[F75HID shared] startWatching];
    if (statusStale) [self refresh:NO];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showWindow];
    return NO;
}

- (void)windowDidMiniaturize:(NSNotification *)note { [self releaseUI]; }
- (void)windowDidDeminiaturize:(NSNotification *)note { if (!uiBuilt) [self build]; if (statusStale) [self refresh:NO]; }

// Drops the whole view tree while hidden or minimized; it is rebuilt from the profile when shown.
- (void)releaseUI {
    if (!uiBuilt) return;
    if (macroRecording) [self stopMacroRecording:NO];
    [statusTimer invalidate]; statusTimer = nil;
    [window makeFirstResponder:nil];
    window.contentView = [NSView new];
    nav = content = nil; status = selectionLabel = brushLabel = applyLabel = connectionText = batteryText = deviceStatusText = hexField = nameField = nil;
    applyButton = nil; keyboard = nil; effect = effectBrightness = speed = direction = palette = latency = sleepPopup = trigger = nil;
    macroText = nil; macroCapture = nil;
    [selected removeAllIndexes]; [swatches removeAllObjects]; [self dropTargets];
    uiBuilt = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->uiBuilt) malloc_zone_pressure_relief(NULL, 0);
    });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (canQuit) { [statusTimer invalidate]; [self saveLocal]; return NSTerminateNow; }
    if (busy || quitting) { [self setStatus:T(@"Aguarde a operação USB terminar.", @"Wait for the USB operation to finish.")]; return NSTerminateCancel; }
    quitting = YES;
    [self saveAllThenQuit];
    return NSTerminateLater;
}

// Mode B (and "Exit and save" in mode A): writes lighting, response time and sleep, then exits for good.
- (void)saveAllThenQuit {
    uint8_t all[10][F75_PACKET];
    [self syncLanguage];
    int count = f75_save_all(all, &profile);
    BOOL pending = dirty;
    if (count < 0) { canQuit = YES; [NSApp replyToApplicationShouldTerminate:YES]; return; }
    [self setStatus:T(@"Gravando luzes, resposta e suspensão no teclado…", @"Saving lighting, response time and sleep to the keyboard…")];
    BOOL started = [self execute:[self sendWork:[NSData dataWithBytes:all length:(NSUInteger)count * F75_PACKET]] success:^{ self->dirty = NO; } sent:NO completion:^(BOOL ok, NSError *error) {
        if (ok || !pending) { self->canQuit = YES; [NSApp replyToApplicationShouldTerminate:YES]; return; }
        NSAlert *alert = [NSAlert new];
        alert.messageText = T(@"Não foi possível gravar no teclado.", @"Could not save to the keyboard.");
        alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@", error.localizedDescription ?: @"", T(@"Sair mesmo assim? Suas mudanças continuam salvas no computador.", @"Exit anyway? Your changes remain saved on this Mac.")];
        [alert addButtonWithTitle:T(@"Tentar de novo", @"Try again")];
        [alert addButtonWithTitle:T(@"Sair sem gravar", @"Exit without saving")];
        [alert addButtonWithTitle:T(@"Cancelar", @"Cancel")];
        [NSApp activateIgnoringOtherApps:YES];
        NSModalResponse answer = [alert runModal];
        if (answer == NSAlertFirstButtonReturn) { [self saveAllThenQuit]; return; }
        if (answer == NSAlertSecondButtonReturn) { self->canQuit = YES; [NSApp replyToApplicationShouldTerminate:YES]; return; }
        self->quitting = NO;
        [NSApp replyToApplicationShouldTerminate:NO];
    }];
    if (!started) { quitting = NO; [NSApp replyToApplicationShouldTerminate:NO]; }
}

- (void)quitWithoutSending { canQuit = YES; [NSApp terminate:nil]; }

#pragma mark Menu bar icon (mode A)

- (void)setupStatusItem {
    if (statusItem) return;
    statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:@"F75 Studio"];
    if (image) statusItem.button.image = image; else statusItem.button.title = @"F75";
    statusItem.button.toolTip = @"F75 Studio";
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    statusItem.menu = menu;
}

- (void)removeStatusItem {
    if (!statusItem) return;
    [NSStatusBar.systemStatusBar removeStatusItem:statusItem];
    statusItem = nil;
}

// Built when the menu opens, so labels always follow the current language.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != statusItem.menu) return;
    [menu removeAllItems];
    [self item:menu title:T(@"Abrir F75 Studio", @"Open F75 Studio") action:@selector(showWindow)];
    [self item:menu title:T(@"Desligar RGB das teclas", @"Turn key RGB off") action:@selector(rgbOffAction)];
    [self item:menu title:T(@"Restaurar minhas cores", @"Restore my colors") action:@selector(rgbOnAction)];
    [menu addItem:[NSMenuItem separatorItem]];
    [self item:menu title:T(@"Sair e gravar no teclado", @"Exit and save to keyboard") action:@selector(terminateAction)];
    [self item:menu title:T(@"Sair sem enviar", @"Exit without sending") action:@selector(quitWithoutSending)];
}
- (void)item:(NSMenu *)menu title:(NSString *)title action:(SEL)action { [menu addItemWithTitle:title action:action keyEquivalent:@""].target = self; }
- (void)rgbOffAction { [self toggleRgb:YES]; }
- (void)rgbOnAction { [self toggleRgb:NO]; }
- (void)terminateAction { [NSApp terminate:nil]; }

- (void)buildMenu {
    NSMenu *bar = [NSMenu new], *app = [NSMenu new], *edit = [NSMenu new], *win = [NSMenu new];
    [app addItemWithTitle:T(@"Sobre o F75 Studio", @"About F75 Studio") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:T(@"Ocultar F75 Studio", @"Hide F75 Studio") action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:T(@"Sair e gravar no teclado", @"Quit and save to keyboard") action:@selector(terminate:) keyEquivalent:@"q"];
    [edit addItemWithTitle:T(@"Desfazer", @"Undo") action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:T(@"Refazer", @"Redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItemWithTitle:T(@"Recortar", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:T(@"Copiar", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:T(@"Colar", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:T(@"Selecionar tudo", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    [win addItemWithTitle:T(@"Minimizar", @"Minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [win addItemWithTitle:T(@"Fechar", @"Close") action:@selector(performClose:) keyEquivalent:@"w"];
    NSArray *menus = @[app, edit, win], *titles = @[@"F75 Studio", T(@"Editar", @"Edit"), T(@"Janela", @"Window")];
    for (NSUInteger i = 0; i < menus.count; i++) {
        NSMenuItem *holder = [bar addItemWithTitle:titles[i] action:NULL keyEquivalent:@""];
        ((NSMenu *)menus[i]).title = titles[i];
        holder.submenu = menus[i];
    }
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = win;
}

#pragma mark View helpers

- (NSTextField *)text:(NSString *)string size:(CGFloat)size color:(unsigned)color {
    NSTextField *label = [NSTextField wrappingLabelWithString:string ?: @""];
    label.font = [NSFont systemFontOfSize:size];
    label.textColor = F75Hex(color);
    label.selectable = NO;
    return label;
}

// The control being clicked may be what triggered the rebuild, so its target is released on the next run loop pass.
- (void)dropTargets {
    NSArray *old = targets;
    targets = [NSMutableArray new];
    dispatch_async(dispatch_get_main_queue(), ^{ [old count]; });
}

- (F75Target *)target:(void (^)(id sender))block {
    F75Target *t = [F75Target new];
    t.block = block;
    [targets addObject:t];
    return t;
}

- (void)bind:(NSControl *)control to:(void (^)(id sender))block {
    F75Target *t = [self target:block];
    control.target = t;
    control.action = @selector(fire:);
}

- (NSButton *)button:(NSString *)title primary:(BOOL)primary action:(void (^)(void))action {
    NSButton *b = [NSButton buttonWithTitle:title target:nil action:NULL];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeLarge;
    if (primary) { b.bezelColor = F75Hex(Accent); b.keyEquivalent = @""; }
    __weak F75Studio *weakSelf = self;
    [self bind:b to:^(id sender) {
        @try { action(); } @catch (NSException *e) { [weakSelf setStatus:e.reason]; }
    }];
    return b;
}

- (NSPopUpButton *)popup:(NSArray<NSString *> *)items index:(NSInteger)index width:(CGFloat)width {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [p addItemsWithTitles:items];
    if (index >= 0 && index < (NSInteger)items.count) [p selectItemAtIndex:index];
    [p.widthAnchor constraintEqualToConstant:width].active = YES;
    return p;
}

- (NSStackView *)vstack:(CGFloat)spacing {
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

- (NSStackView *)row:(NSStackView *)parent views:(NSArray<NSView *> *)views {
    NSStackView *r = [NSStackView stackViewWithViews:views];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 8;
    [parent addArrangedSubview:r];
    return r;
}

- (void)full:(NSStackView *)parent view:(NSView *)view {
    [parent addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:parent.widthAnchor].active = YES;
}

- (void)pin:(NSView *)child in:(NSView *)parent insets:(NSEdgeInsets)e {
    [parent addSubview:child];
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:e.left],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-e.right],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:e.top],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-e.bottom]]];
}

- (NSStackView *)card:(NSString *)title desc:(NSString *)desc {
    F75Panel *panel = [F75Panel panelWithFill:Panel border:0x293547 radius:16];
    NSStackView *stack = [self vstack:10];
    [self pin:stack in:panel insets:NSEdgeInsetsMake(24, 24, 24, 24)];
    [self full:stack view:[self text:title size:19 color:Ink]];
    if (desc) [self full:stack view:[self text:desc size:13 color:Muted]];
    [self full:content view:panel];
    return stack;
}

- (NSView *)field:(NSString *)label control:(NSView *)control {
    NSStackView *s = [self vstack:4];
    [s addArrangedSubview:[self text:label size:12 color:Muted]];
    [s addArrangedSubview:control];
    return s;
}

- (NSView *)spacer:(CGFloat)height {
    NSView *v = [NSView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.heightAnchor constraintEqualToConstant:height].active = YES;
    return v;
}

- (NSScrollView *)textArea:(CGFloat)height monospace:(BOOL)monospace text:(NSString *)string {
    NSScrollView *scroll = [NSTextView scrollableTextView];
    NSTextView *tv = scroll.documentView;
    tv.richText = NO;
    tv.automaticQuoteSubstitutionEnabled = NO; tv.automaticDashSubstitutionEnabled = NO; tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO; tv.continuousSpellCheckingEnabled = NO;
    tv.font = monospace ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:14];
    tv.textContainerInset = NSMakeSize(8, 8);
    tv.string = string ?: @"";
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:height].active = YES;
    return scroll;
}

#pragma mark Build

- (void)build {
    @autoreleasepool {
        if (macroRecording) [self stopMacroRecording:NO];
        [self dropTargets]; [swatches removeAllObjects];
        deviceStatusText = nil; keyboard = nil; hexField = nil; brushLabel = nil; selectionLabel = nil; nameField = nil; macroCapture = nil; macroText = nil;
        applyLabel = nil; applyButton = nil;
        NSView *root = [NSView new];

        F75Panel *sidebar = [F75Panel panelWithFill:0x101723 border:0x101723 radius:0];
        [root addSubview:sidebar];
        [NSLayoutConstraint activateConstraints:@[[sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
                                                  [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor], [sidebar.widthAnchor constraintEqualToConstant:215]]];
        nav = [self vstack:7];
        [sidebar addSubview:nav];
        [NSLayoutConstraint activateConstraints:@[[nav.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:20], [nav.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-14],
                                                  [nav.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:25]]];
        [nav addArrangedSubview:[self text:@"F75  STUDIO" size:25 color:0xEDF9F4]];
        [nav addArrangedSubview:[self text:T(@"CONTROLE DO SEU TECLADO", @"KEYBOARD CONTROL") size:10 color:Accent]];
        [nav addArrangedSubview:[self spacer:26]];
        [nav addArrangedSubview:[self text:T(@"PERSONALIZAR", @"PERSONALIZE") size:11 color:Muted]];
        NSArray *ids = @[@"light", @"effects", @"performance", @"macros", @"profiles", @"device"];
        NSArray *labels = @[T(@"Cores por tecla", @"Per-key colors"), T(@"Efeitos RGB", @"RGB effects"), T(@"Desempenho", @"Performance"), @"Macros", T(@"Perfis", @"Profiles"), T(@"Dispositivo", @"Device")];
        __weak F75Studio *weakSelf = self;
        for (NSUInteger i = 0; i < ids.count; i++) {
            NSString *pageId = ids[i];
            NSButton *b = [self button:[NSString stringWithFormat:@"%02lu    %@", (unsigned long)i + 1, labels[i]] primary:NO action:^{ F75Studio *s = weakSelf; s->page = pageId; [s build]; }];
            b.bezelStyle = NSBezelStyleRecessed;
            [b setButtonType:NSButtonTypePushOnPushOff];
            b.state = [page isEqualToString:pageId] ? NSControlStateValueOn : NSControlStateValueOff;
            b.alignment = NSTextAlignmentLeft;
            if ([page isEqualToString:pageId]) b.contentTintColor = F75Hex(Accent);
            [self full:nav view:b];
        }
        [nav addArrangedSubview:[self spacer:22]];
        [nav addArrangedSubview:[self text:T(@"IDIOMA", @"LANGUAGE") size:11 color:Muted]];
        NSPopUpButton *languages = [self popup:@[@"Português (Brasil)", @"English"] index:[language isEqualToString:@"en"] ? 1 : 0 width:172];
        [self bind:languages to:^(NSPopUpButton *sender) {
            F75Studio *s = weakSelf;
            s->language = sender.indexOfSelectedItem == 1 ? @"en" : @"pt-BR";
            [s saveLocal]; [s buildMenu]; [s build];
        }];
        [nav addArrangedSubview:languages];
        [nav addArrangedSubview:[self spacer:14]];
        connectionText = [self text:@"" size:12 color:Accent];
        batteryText = [self text:@"" size:11 color:Muted];
        [self full:nav view:connectionText];
        [self full:nav view:batteryText];
        [self full:nav view:[self text:T(@"Versão 1.0 final  •  macOS", @"Version 1.0 final  •  macOS") size:11 color:Muted]];

        NSStackView *column = [self vstack:0];
        column.distribution = NSStackViewDistributionFill;
        [root addSubview:column];
        [NSLayoutConstraint activateConstraints:@[[column.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor], [column.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
                                                  [column.topAnchor constraintEqualToAnchor:root.topAnchor], [column.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];
        NSScrollView *scroll = [NSScrollView new];
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground = NO;
        scroll.automaticallyAdjustsContentInsets = NO;
        F75FlippedView *document = [F75FlippedView new];
        document.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.documentView = document;
        [NSLayoutConstraint activateConstraints:@[[document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor], [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
                                                  [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]]];
        content = [self vstack:16];
        [self pin:content in:document insets:NSEdgeInsetsMake(28, 30, 16, 30)];
        [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
        [scroll setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
        [self full:column view:scroll];

        [content addArrangedSubview:[self text:@"FREE WOLF  /  F75" size:11 color:Accent]];
        [content addArrangedSubview:[self text:labels[[ids indexOfObject:page]] size:32 color:Ink]];
        if ([page isEqualToString:@"light"]) [self lighting];
        else if ([page isEqualToString:@"effects"]) [self effects];
        else if ([page isEqualToString:@"performance"]) [self performance];
        else if ([page isEqualToString:@"macros"]) [self macros];
        else if ([page isEqualToString:@"profiles"]) [self profiles];
        else [self device];

        if ([page isEqualToString:@"light"]) {
            F75Panel *command = [F75Panel panelWithFill:0x172621 border:0x355446 radius:0];
            NSStackView *bar = [NSStackView new];
            bar.translatesAutoresizingMaskIntoConstraints = NO;
            applyLabel = [self text:@"" size:13 color:0xDBF6E7];
            applyButton = [self button:T(@"Aplicar agora no F75", @"Apply to F75 now") primary:YES action:^{ [weakSelf applyColors]; }];
            [bar addView:applyLabel inGravity:NSStackViewGravityLeading];
            [bar addView:applyButton inGravity:NSStackViewGravityTrailing];
            [applyLabel setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
            [self pin:bar in:command insets:NSEdgeInsetsMake(10, 24, 8, 20)];
            [self full:column view:command];
        }
        F75Panel *footer = [F75Panel panelWithFill:0x0A0F16 border:0x0A0F16 radius:0];
        status = [self text:lastStatus.length ? lastStatus : T(@"Consultando F75…", @"Checking F75…") size:12 color:Muted];
        [self pin:status in:footer insets:NSEdgeInsetsMake(11, 20, 11, 20)];
        [self full:column view:footer];

        window.contentView = root;
        uiBuilt = YES;
        [self updateDeviceLabels];
        [self updateApply];
        [self repaint];
        [self setEnabled:!busy];
    }
}

- (void)setEnabled:(BOOL)enabled {
    for (NSView *v in @[nav ?: [NSNull null], content ?: [NSNull null]]) if ([v isKindOfClass:[NSView class]]) [self enable:v on:enabled];
    applyButton.enabled = enabled;
}
- (void)enable:(NSView *)view on:(BOOL)on {
    if ([view isKindOfClass:[NSControl class]]) ((NSControl *)view).enabled = on;
    for (NSView *child in view.subviews) [self enable:child on:on];
}

#pragma mark Pages

- (void)lighting {
    __weak F75Studio *weakSelf = self;
    NSStackView *guide = [self card:T(@"1. Escolha uma cor", @"1. Choose a color") desc:T(@"A cor escolhida vira seu pincel. Clique nas teclas do desenho para pintar a prévia.", @"Your chosen color becomes the brush. Click keys in the diagram to paint the preview.")];
    NSMutableArray *row = [NSMutableArray new];
    for (NSNumber *c in @[@0xA8F0C9, @0x5BC8FF, @0x8878F8, @0xFF77AB, @0xFF985C, @0xFFD46A, @0xF8FBFF, @0x000000]) {
        F75Swatch *swatch = [F75Swatch new];
        swatch.color = c.unsignedIntValue; swatch.active = swatch.color == activeColor;
        swatch.toolTip = [NSString stringWithFormat:@"#%06X", swatch.color];
        swatch.clicked = ^(unsigned color) { [weakSelf chooseColor:color]; };
        swatch.translatesAutoresizingMaskIntoConstraints = NO;
        [swatch.widthAnchor constraintEqualToConstant:43].active = YES;
        [swatch.heightAnchor constraintEqualToConstant:43].active = YES;
        swatches[c] = swatch;
        [row addObject:swatch];
    }
    [self row:guide views:row];
    hexField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"#%06X", activeColor]];
    hexField.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    hexField.delegate = self;
    [hexField.widthAnchor constraintEqualToConstant:126].active = YES;
    [self bind:hexField to:^(id sender) { unsigned color; F75Studio *s = weakSelf; if ([s tryColor:&color]) { [s chooseColor:color]; [s->window makeFirstResponder:nil]; } }];
    brushLabel = [self text:@"" size:13 color:Accent];
    [self row:guide views:@[hexField, [self button:T(@"Mais cores…", @"More colors…") primary:NO action:^{ [weakSelf showColorPanel]; }], brushLabel]];
    [self updateBrush];

    NSStackView *c = [self card:T(@"2. Pinte o teclado", @"2. Paint the keyboard") desc:T(@"Clique numa tecla para pintá-la. ⌘ + clique marca várias teclas para pintar juntas.", @"Click a key to paint it. ⌘ + click marks multiple keys to paint together.")];
    keyboard = [F75KeyboardView new];
    keyboard.translatesAutoresizingMaskIntoConstraints = NO;
    keyboard.profile = &profile;
    keyboard.selection = selected;
    keyboard.keyClicked = ^(int index, BOOL toggle) { [weakSelf keyClicked:index toggle:toggle]; };
    [c addArrangedSubview:keyboard];
    NSLayoutConstraint *preferred = [keyboard.widthAnchor constraintEqualToConstant:740];
    preferred.priority = 500;
    [NSLayoutConstraint activateConstraints:@[preferred, [keyboard.widthAnchor constraintLessThanOrEqualToAnchor:c.widthAnchor], [keyboard.widthAnchor constraintLessThanOrEqualToConstant:740],
                                              [keyboard.heightAnchor constraintEqualToAnchor:keyboard.widthAnchor multiplier:267.0 / 600.0]]];
    selectionLabel = [self text:@"" size:12 color:Muted];
    [self full:c view:selectionLabel];
    [self row:c views:@[[self button:T(@"Pintar seleção", @"Paint selected") primary:YES action:^{ [weakSelf paint:NO]; }],
                        [self button:T(@"Pintar todas", @"Paint all") primary:NO action:^{ [weakSelf paint:YES]; }],
                        [self button:T(@"Desfazer", @"Undo") primary:NO action:^{ [weakSelf undoColors]; }],
                        [self button:T(@"Limpar todas", @"Clear all") primary:NO action:^{
                            F75Studio *s = weakSelf; [s rememberColors];
                            for (int i = 0; i < F75_KEY_COUNT; i++) s->profile.colors[f75_keys[i].index] = 0;
                            [s->selected removeAllIndexes]; [s changed]; }]]];
    NSStackView *presets = [self card:T(@"Comece com um estilo", @"Start with a style") desc:T(@"Um estilo preenche a prévia; depois você pode ajustar tecla por tecla.", @"A style fills the preview; then you can adjust individual keys.")];
    NSArray *names = @[@"Mint", @"Sunset", @"Aurora", @"WASD"];
    NSMutableArray *presetButtons = [NSMutableArray new];
    for (int i = 0; i < 4; i++) [presetButtons addObject:[self button:names[i] primary:NO action:^{ [weakSelf preset:i]; }]];
    [self row:presets views:presetButtons];
    NSStackView *settings = [self card:T(@"3. Ajuste e aplique", @"3. Adjust and apply") desc:T(@"O brilho também aparece na prévia. Use o botão fixo na parte inferior para enviar as cores ao F75.", @"Brightness is shown in the preview too. Use the fixed button at the bottom to send colors to the F75.")];
    NSSlider *slider = [NSSlider sliderWithValue:profile.brightness minValue:0 maxValue:100 target:nil action:NULL];
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:260].active = YES;
    NSTextField *value = [self text:[NSString stringWithFormat:@"%d%%", profile.brightness] size:16 color:Accent];
    [self bind:slider to:^(NSSlider *sender) {
        F75Studio *s = weakSelf; int v = (int)lround(sender.doubleValue);
        if (s->profile.brightness == v) return;
        s->profile.brightness = v; value.stringValue = [NSString stringWithFormat:@"%d%%", v];
        s->dirty = YES; [s repaint]; [s updateApply]; [s scheduleSave];
    }];
    [self row:settings views:@[[self field:T(@"Brilho do RGB", @"RGB brightness") control:slider], value]];
}

- (void)effects {
    __weak F75Studio *weakSelf = self;
    NSStackView *card = [self card:T(@"Efeitos do teclado", @"Keyboard effects") desc:T(@"Escolha uma animação do firmware e envie ao F75.", @"Choose a firmware animation and send it to the F75.")];
    NSArray *pt = @[@"Ondas horizontais", @"Estrelas", @"Ondas verticais", @"Expansão dupla", @"Ciclo de cores", @"Caleidoscópio", @"Estático", @"Respiração", @"Cruzamento", @"Aurora", @"Respiração por tecla", @"Panorama", @"Serpente", @"Tornado", @"Três acima / abaixo", @"Chuva", @"Catavento", @"Senoidal", @"Cavalgada", @"Entrelaçado", @"Ritmo de música (experimental)", @"Ritmo de tela (experimental)"];
    NSArray *en = @[@"Horizontal ripples", @"Stars", @"Vertical ripples", @"Double expansion", @"Spectrum cycle", @"Kaleidoscope", @"Static", @"Breathing", @"Crossing", @"Aurora", @"Per-key breathing", @"Panorama", @"Snake", @"Tornado", @"Top / bottom three", @"Rain", @"Windmill", @"Sine wave", @"Gallop", @"Crisscross", @"Music rhythm (experimental)", @"Screen rhythm (experimental)"];
    static const int modes[22] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 22, 23};
    NSInteger current = 0;
    for (int i = 0; i < 22; i++) if (modes[i] == profile.effect_mode) current = i;
    NSArray *five = @[@"1", @"2", @"3", @"4", @"5"];
    effect = [self popup:[language isEqualToString:@"en"] ? en : pt index:current width:280];
    effectBrightness = [self popup:five index:profile.effect_brightness - 1 width:80];
    speed = [self popup:five index:profile.effect_speed - 1 width:80];
    direction = [self popup:@[@"0", @"1", @"2", @"3"] index:profile.effect_direction width:80];
    palette = [self popup:[language isEqualToString:@"en"] ? @[@"Rainbow", @"Red", @"Orange", @"Yellow", @"Green", @"Cyan", @"Blue", @"Purple", @"White"] : @[@"Arco-íris", @"Vermelho", @"Laranja", @"Amarelo", @"Verde", @"Ciano", @"Azul", @"Roxo", @"Branco"] index:profile.effect_palette width:150];
    [self row:card views:@[[self field:T(@"Efeito", @"Effect") control:effect], [self field:T(@"Paleta", @"Palette") control:palette]]];
    [self row:card views:@[[self field:T(@"Brilho", @"Brightness") control:effectBrightness], [self field:T(@"Velocidade", @"Speed") control:speed], [self field:T(@"Direção", @"Direction") control:direction]]];
    [self full:card view:[self text:T(@"Os modos 22 e 23 constam no layout do driver original, mas podem depender do módulo de áudio/tela dele. No F75 Studio, ficam em modo experimental.", @"Modes 22 and 23 are listed in the original driver layout, but may depend on its audio/screen module. They are experimental in F75 Studio.") size:12 color:Muted]];
    [self full:card view:[self text:T(@"Alguns efeitos usam cores ou direção próprias. Volte a Cores por tecla para aplicar seu desenho personalizado.", @"Some effects use their own colors or direction. Return to Per-key colors to apply your custom layout.") size:12 color:Muted]];
    [card addArrangedSubview:[self button:T(@"Enviar efeito", @"Send effect") primary:YES action:^{
        F75Studio *s = weakSelf;
        int mode = modes[s->effect.indexOfSelectedItem], br = (int)s->effectBrightness.indexOfSelectedItem + 1, sp = (int)s->speed.indexOfSelectedItem + 1, di = (int)s->direction.indexOfSelectedItem, pa = (int)s->palette.indexOfSelectedItem;
        uint8_t packet[F75_PACKET];
        if (f75_effect(packet, mode, br, sp, di, pa)) return;
        [s execute:[s sendWork:[NSData dataWithBytes:packet length:F75_PACKET]] success:^{
            s->profile.effect_mode = mode; s->profile.effect_brightness = br; s->profile.effect_speed = sp; s->profile.effect_direction = di; s->profile.effect_palette = pa;
            s->profile.light_mode = F75_LIGHT_EFFECT; s->rgbOff = NO; [s saveLocal];
        } sent:YES completion:nil];
    }]];
    [self row:card views:@[[self button:T(@"Desligar RGB das teclas", @"Turn key RGB off") primary:NO action:^{ [weakSelf toggleRgb:YES]; }],
                           [self button:T(@"Restaurar minhas cores", @"Restore my colors") primary:NO action:^{ [weakSelf toggleRgb:NO]; }]]];
    NSStackView *note = [self card:T(@"Luz da barra lateral", @"Side light bar") desc:nil];
    [self full:note view:[self text:T(@"O driver não inclui essa barra no mapa RGB por tecla e não foi encontrado comando separado para desligá-la. Portanto, o botão Limpar todas apaga as teclas RGB, mas pode não apagar a barra.", @"The driver does not include this bar in the per-key RGB map, and no separate off command was found. Clear all turns off key RGB, but may leave the bar on.") size:13 color:Muted]];
    [self full:note view:[self text:T(@"Tentativa manual não confirmada para este modelo: pressione Fn + Shift esquerdo para alternar o efeito da barra. Esse atalho aparece em manuais de outras variantes F75; se não mudar nada, não insista nem use combinações de reset.", @"Unconfirmed manual attempt for this model: press Fn + Left Shift to toggle the strip effect. This shortcut appears in manuals for other F75 variants; if nothing changes, do not keep trying or use reset combinations.") size:13 color:Muted]];
}

- (void)performance {
    __weak F75Studio *weakSelf = self;
    NSStackView *c = [self card:T(@"Resposta das teclas", @"Key response") desc:T(@"Três níveis presentes no driver original. O nível 1 é a opção de menor atraso; não altera a taxa USB nem promete latência zero.", @"Three levels found in the original driver. Level 1 is the lowest delay option; it does not change USB polling or promise zero latency.")];
    latency = [self popup:[language isEqualToString:@"en"] ? @[@"1 · Lowest delay", @"2 · Balanced", @"3 · More filtering"] : @[@"1 · Menor atraso", @"2 · Equilibrado", @"3 · Mais filtragem"] index:profile.response - 1 width:250];
    [c addArrangedSubview:latency];
    [self full:c view:[self text:T(@"Referência do fabricante por nível (não medida aqui): USB ≈ 2–3 / 4–5 / 6–7 ms. Se houver digitação duplicada, aumente o nível.", @"Vendor reference per level (not measured here): USB ≈ 2–3 / 4–5 / 6–7 ms. If you encounter double typing, raise the level.") size:13 color:Muted]];
    [c addArrangedSubview:[self button:T(@"Aplicar tempo de resposta", @"Apply response time") primary:YES action:^{
        F75Studio *s = weakSelf; int level = (int)s->latency.indexOfSelectedItem + 1; uint8_t p[F75_PACKET]; f75_response_time(p, level);
        [s execute:[s sendWork:[NSData dataWithBytes:p length:F75_PACKET]] success:^{ s->profile.response = level; [s saveLocal]; } sent:YES completion:nil];
    }]];
    NSStackView *sl = [self card:T(@"Suspensão", @"Sleep") desc:T(@"Escolha o tempo de inatividade oferecido pelo firmware.", @"Choose the inactivity timeout offered by the firmware.")];
    sleepPopup = [self popup:@[T(@"2 minutos", @"2 minutes"), T(@"15 minutos", @"15 minutes"), T(@"30 minutos", @"30 minutes"), T(@"Não suspender", @"Never sleep")] index:profile.sleep - 1 width:250];
    [sl addArrangedSubview:sleepPopup];
    [sl addArrangedSubview:[self button:T(@"Aplicar suspensão", @"Apply sleep setting") primary:NO action:^{
        F75Studio *s = weakSelf; int level = (int)s->sleepPopup.indexOfSelectedItem + 1; uint8_t p[F75_PACKET]; f75_sleep(p, level);
        [s execute:[s sendWork:[NSData dataWithBytes:p length:F75_PACKET]] success:^{ s->profile.sleep = level; [s saveLocal]; } sent:YES completion:nil];
    }]];
    NSStackView *quick = [self card:T(@"Preset competitivo", @"Competitive preset") desc:T(@"Envia nível 1 e desativa suspensão. A iluminação fica como está.", @"Sends level 1 and disables sleep. Lighting stays as it is.")];
    [quick addArrangedSubview:[self button:T(@"Ativar baixa latência", @"Enable low latency") primary:YES action:^{
        F75Studio *s = weakSelf; uint8_t p[2][F75_PACKET]; f75_response_time(p[0], 1); f75_sleep(p[1], 4);
        [s execute:[s sendWork:[NSData dataWithBytes:p length:sizeof p]] success:^{ s->profile.response = 1; s->profile.sleep = 4; [s saveLocal]; [s build]; } sent:YES completion:nil];
    }]];
    NSStackView *test = [self card:T(@"Área de digitação", @"Typing area") desc:T(@"Use para observar repetições após mudar o nível. Não é uma medição de latência física.", @"Use this to observe repeated characters after changing the level. This is not a physical latency measurement.")];
    [self full:test view:[self textArea:100 monospace:NO text:@""]];
}

- (void)macros {
    __weak F75Studio *weakSelf = self;
    NSStackView *c = [self card:T(@"Sequências no teclado · experimental", @"On-keyboard sequences · experimental") desc:T(@"Formato identificado no executável original; execução física ainda não validada. Até 60 eventos, com soltura de todas as teclas. Use uma tecla secundária para experimentar.", @"Format identified in the original executable; physical execution is not yet validated. Up to 60 events, with all keys released. Use a secondary key to try it.")];
    NSMutableArray *keysForTrigger = [NSMutableArray new], *titles = [NSMutableArray new];
    NSInteger end = 0;
    for (int i = 0; i < F75_KEY_COUNT; i++) {
        if (strcmp(f75_keys[i].name, "Fn") == 0) continue;
        if (strcmp(f75_keys[i].name, "End") == 0) end = (NSInteger)keysForTrigger.count;
        [keysForTrigger addObject:@(f75_keys[i].index)];
        [titles addObject:[NSString stringWithFormat:@"%s · %d", f75_keys[i].name, f75_keys[i].index]];
    }
    triggerKeys = keysForTrigger;
    trigger = [self popup:titles index:end width:250];
    [c addArrangedSubview:[self field:T(@"Tecla de acionamento · camada principal", @"Trigger key · main layer") control:trigger]];
    // On a Mac the shortcuts use Command (HID usage 227, the Win key on PC layouts).
    NSPopUpButton *preset = [self popup:@[T(@"Copiar (⌘C)", @"Copy (⌘C)"), T(@"Colar (⌘V)", @"Paste (⌘V)"), T(@"Salvar (⌘S)", @"Save (⌘S)"), T(@"Desfazer (⌘Z)", @"Undo (⌘Z)")] index:0 width:250];
    [self row:c views:@[preset, [self button:T(@"Carregar sequência", @"Load sequence") primary:NO action:^{
        F75Studio *s = weakSelf; static const int codes[4] = {6, 25, 22, 29}; int code = codes[preset.indexOfSelectedItem];
        f75_macro_event e[4] = {{227, 0, 10}, {code, 0, 20}, {code, 1, 10}, {227, 1, 10}};
        memcpy(s->events, e, sizeof e); s->eventCount = 4; [s showEvents];
    }]]];
    [c addArrangedSubview:[self text:T(@"Gravar uma sequência", @"Record a sequence") size:15 color:Ink]];
    [self row:c views:@[[self button:T(@"Iniciar gravação", @"Start recording") primary:YES action:^{ [weakSelf startMacroRecording]; }],
                        [self button:T(@"Parar gravação", @"Stop recording") primary:NO action:^{ [weakSelf stopMacroRecording:YES]; }]]];
    macroCapture = [F75KeyCaptureView new];
    macroCapture.translatesAutoresizingMaskIntoConstraints = NO;
    macroCapture.text = T(@"Clique em Iniciar gravação e digite aqui…", @"Click Start recording and type here…");
    macroCapture.keyEvent = ^(unsigned short keyCode, BOOL down) { [weakSelf recordKey:keyCode down:down]; };
    [macroCapture.heightAnchor constraintEqualToConstant:55].active = YES;
    [self full:c view:macroCapture];
    [self full:c view:[self text:T(@"Editor de eventos: Code = uso USB HID; Release = soltar; Delay = intervalo em ms (quantizado pelo firmware).", @"Event editor: Code = USB HID usage; Release = key up; Delay = interval in ms (quantized by firmware).") size:13 color:Muted]];
    NSScrollView *editor = [self textArea:160 monospace:YES text:@"[]"];
    macroText = editor.documentView;
    [self full:c view:editor];
    [self showEvents];
    [self full:c view:[self text:T(@"Enviar substitui a função da tecla escolhida na camada principal. Restaure a função padrão no botão abaixo.", @"Sending replaces the selected key's main-layer function. Restore its default function using the button below.") size:13 color:Muted]];
    [self row:c views:@[[self button:T(@"Enviar macro experimental", @"Send experimental macro") primary:NO action:^{ [weakSelf sendMacro]; }],
                        [self button:T(@"Restaurar esta tecla", @"Restore this key") primary:NO action:^{
                            F75Studio *s = weakSelf; uint8_t p[F75_PACKET];
                            if (f75_restore_key(p, s->triggerKeys[s->trigger.indexOfSelectedItem].intValue)) return;
                            [s execute:[s sendWork:[NSData dataWithBytes:p length:F75_PACKET]] success:nil sent:YES completion:nil];
                        }]]];
}

- (void)profiles {
    __weak F75Studio *weakSelf = self;
    NSStackView *c = [self card:T(@"Seus perfis", @"Your profiles") desc:T(@"Cores e preferências salvas em JSON no computador; o mesmo arquivo funciona no Windows e no Mac. Importar carrega a prévia; nada é enviado automaticamente.", @"Colors and preferences saved as JSON on your computer; the same file works on Windows and Mac. Import loads the preview; nothing is sent automatically.")];
    nameField = [NSTextField textFieldWithString:[NSString stringWithUTF8String:profile.name] ?: @""];
    nameField.delegate = self;
    [self full:c view:nameField];
    [self row:c views:@[[self button:T(@"Exportar perfil", @"Export profile") primary:YES action:^{ [weakSelf exportProfile]; }],
                        [self button:T(@"Importar perfil", @"Import profile") primary:NO action:^{ [weakSelf importProfile]; }]]];
    [c addArrangedSubview:[self button:T(@"Aplicar cores e desempenho do perfil", @"Apply profile colors and performance") primary:YES action:^{
        F75Studio *s = weakSelf; uint8_t p[10][F75_PACKET];
        if (f75_profile_validate(&s->profile, NULL) || f75_custom(p, s->profile.colors, s->profile.brightness) || f75_response_time(p[8], s->profile.response) || f75_sleep(p[9], s->profile.sleep)) return;
        [s execute:[s sendWork:[NSData dataWithBytes:p length:sizeof p]] success:^{ s->dirty = NO; s->rgbOff = NO; s->profile.light_mode = F75_LIGHT_CUSTOM; [s saveLocal]; } sent:YES completion:nil];
    }]];
    [self full:c view:[self text:T(@"O estado local é salvo automaticamente. Não há inicialização automática, serviço residente ou animação contínua no computador.", @"Local state is saved automatically. There is no auto-start, resident service, or continuous animation running on your computer.") size:13 color:Muted]];
}

- (void)device {
    __weak F75Studio *weakSelf = self;
    NSStackView *c = [self card:@"FREE WOLF F75" desc:T(@"Conexão e bateria", @"Connection and battery")];
    deviceStatusText = [self text:@"" size:15 color:Accent];
    [self full:c view:deviceStatusText];
    [self full:c view:[self text:@"VID 1A2C   /   PID A073   /   HID FF02:0002" size:15 color:Accent]];
    [self full:c view:[self text:T(@"Configurações pelo USB. Receptor 2,4 GHz: consulta experimental de status. Bluetooth: identificação quando o macOS expõe o nome F75; bateria pode ficar indisponível.", @"Settings use USB. The 2.4 GHz receiver has experimental status queries. Bluetooth is identified when macOS exposes the F75 name; battery may be unavailable.") size:13 color:Muted]];
    [c addArrangedSubview:[self button:T(@"Consultar conexão e bateria", @"Check connection and battery") primary:NO action:^{ [weakSelf refresh:YES]; }]];
    NSStackView *cap = [self card:T(@"O que está confirmado", @"What is confirmed") desc:nil];
    [self full:cap view:[self text:T(@"Conexão, leitura de status e cores RGB por tecla: verificadas neste teclado no Windows. No Mac, o transporte USB ainda precisa ser conferido no seu teclado.\n20 efeitos identificados e dois modos de ritmo experimentais declarados no driver. Resposta e suspensão: comandos identificados; comportamento precisa ser conferido.\nMacros: formato identificado, experimental.\nBarra lateral: comando independente ainda desconhecido.", @"Connection, status read and per-key RGB: verified on this keyboard on Windows. On the Mac, the USB transport still needs checking on your keyboard.\n20 identified effects and two experimental rhythm modes declared by the driver. Response time and sleep: commands identified; behavior needs checking.\nMacros: format identified, experimental.\nSide bar: independent command still unknown.") size:14 color:Muted]];
    NSStackView *support = [self card:T(@"Diagnóstico", @"Diagnostics") desc:nil];
    [self full:support view:[self text:T(@"O aplicativo grava quando você aplica ajustes e, no modo Fechar de vez, grava luzes, resposta e suspensão ao sair. Sucesso de envio significa que o macOS aceitou os pacotes USB; não comprova latência nem persistência após desligar o teclado.", @"The app writes when you apply settings and, in Close for good mode, saves lighting, response time and sleep on exit. A successful send means macOS accepted the USB packets; it does not prove latency or persistence after the keyboard is powered off.") size:13 color:Muted]];
    [support addArrangedSubview:[self button:T(@"Exportar diagnóstico", @"Export diagnostics") primary:NO action:^{ [weakSelf exportDiagnostics]; }]];

    NSStackView *a = [self card:T(@"Ao fechar o F75 Studio", @"When closing F75 Studio") desc:T(@"O F75 guarda as configurações no próprio teclado, então o F75 Studio não precisa ficar aberto.", @"The F75 stores its settings on the keyboard itself, so F75 Studio does not need to stay open.")];
    NSButton *close = [NSButton radioButtonWithTitle:T(@"Gravar no teclado e fechar de vez (recomendado): grava luzes, resposta e suspensão e libera toda a memória", @"Save to keyboard and close for good (recommended): saves lighting, response time and sleep and frees all memory") target:nil action:NULL];
    NSButton *stay = [NSButton radioButtonWithTitle:T(@"Ficar em segundo plano na barra de menus: sem janela e sem ícone no Dock, CPU quase zero, poucos MiB de RAM", @"Stay in the background in the menu bar: no window and no Dock icon, near-zero CPU, a few MiB of RAM") target:nil action:NULL];
    close.state = profile.keep_in_tray ? NSControlStateValueOff : NSControlStateValueOn;
    stay.state = profile.keep_in_tray ? NSControlStateValueOn : NSControlStateValueOff;
    void (^choose)(id) = ^(NSButton *sender) {
        F75Studio *s = weakSelf;
        s->profile.keep_in_tray = sender == stay;
        close.state = sender == stay ? NSControlStateValueOff : NSControlStateValueOn;
        stay.state = sender == stay ? NSControlStateValueOn : NSControlStateValueOff;
        if (s->profile.keep_in_tray) [s setupStatusItem]; else [s removeStatusItem];
        [s saveLocal];
    };
    [self bind:close to:choose];
    [self bind:stay to:choose];
    [self full:a view:close];
    [self full:a view:stay];
    [self full:a view:[self text:T(@"Em segundo plano, fechar ou minimizar só esconde a janela; para sair, use o ícone da barra de menus.", @"In the background, closing or minimizing only hides the window; to quit, use the menu bar icon.") size:12 color:Muted]];
}

#pragma mark Colors

- (void)keyClicked:(int)index toggle:(BOOL)toggle {
    if (toggle) {
        if ([selected containsIndex:(NSUInteger)index]) [selected removeIndex:(NSUInteger)index]; else [selected addIndex:(NSUInteger)index];
        [self repaint];
        return;
    }
    unsigned color;
    if (![self tryColor:&color]) return;
    [self rememberColors];
    profile.colors[index] = (int)color;
    [selected removeAllIndexes];
    [self changed];
}

- (void)repaint {
    keyboard.needsDisplay = YES;
    if (selectionLabel) selectionLabel.stringValue = selected.count ? [NSString stringWithFormat:@"%lu%@", (unsigned long)selected.count, T(@" tecla(s) marcadas • use Pintar seleção", @" key(s) selected • use Paint selected")] : T(@"Clique numa tecla para pintá-la com a cor escolhida.", @"Click a key to paint it with the chosen color.");
    [self updateApply];
}

- (void)updateApply {
    if (!applyLabel || !applyButton) return;
    applyLabel.stringValue = rgbOff && !dirty ? T(@"RGB desligado. Reaplicar restaura suas cores.", @"RGB off. Reapply restores your colors.") : dirty ? T(@"● Prévia alterada — clique para enviar agora ao F75.", @"● Preview changed — click to send to F75 now.") : T(@"Sem alterações pendentes. Você pode reaplicar o perfil.", @"No pending changes. You can reapply the profile.");
    applyButton.title = dirty ? T(@"Aplicar agora no F75", @"Apply to F75 now") : T(@"Reaplicar cores no F75", @"Reapply colors to F75");
}

- (void)updateBrush {
    if (brushLabel) brushLabel.stringValue = [NSString stringWithFormat:@"%@#%06X", T(@"Pincel ativo: ", @"Active brush: "), activeColor];
    [swatches enumerateKeysAndObjectsUsingBlock:^(NSNumber *color, F75Swatch *swatch, BOOL *stop) { swatch.active = color.unsignedIntValue == self->activeColor; }];
}

- (void)chooseColor:(unsigned)color {
    activeColor = color & 0xffffff;
    hexField.stringValue = [NSString stringWithFormat:@"#%06X", activeColor];
    [self updateBrush];
}

- (BOOL)tryColor:(unsigned *)color {
    *color = activeColor;
    if (!hexField) return YES;
    NSString *s = [[hexField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] stringByReplacingOccurrencesOfString:@"#" withString:@""];
    NSScanner *scanner = [NSScanner scannerWithString:s];
    unsigned value;
    if (s.length == 6 && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound && [scanner scanHexInt:&value]) {
        activeColor = value; *color = value; [self updateBrush];
        return YES;
    }
    [self setStatus:T(@"Cor inválida. Use #RRGGBB.", @"Invalid color. Use #RRGGBB.")];
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (note.object == hexField) { unsigned color; if ([self tryColor:&color]) [self chooseColor:color]; }
}

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != nameField) return;
    NSString *name = nameField.stringValue;
    if (name.length > 80) { name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 79)]]; nameField.stringValue = name; }
    if ([name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) return;
    strlcpy(profile.name, name.UTF8String, sizeof profile.name);
    [self scheduleSave];
}

- (void)showColorPanel {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = NO;
    panel.color = F75Hex(activeColor);
    [panel setTarget:self];
    [panel setAction:@selector(colorPanelChanged:)];
    [panel orderFront:nil];
}

- (void)colorPanelChanged:(NSColorPanel *)panel {
    NSColor *c = [panel.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c) return;
    unsigned r = (unsigned)lround(c.redComponent * 255), g = (unsigned)lround(c.greenComponent * 255), b = (unsigned)lround(c.blueComponent * 255);
    [self chooseColor:(r << 16) | (g << 8) | b];
}

- (void)rememberColors {
    [colorUndo addObject:[NSData dataWithBytes:profile.colors length:sizeof profile.colors]];
    if (colorUndo.count > 30) [colorUndo removeObjectAtIndex:0];
}

- (void)undoColors {
    if (!colorUndo.count) { [self setStatus:T(@"Nada para desfazer.", @"Nothing to undo.")]; return; }
    memcpy(profile.colors, colorUndo.lastObject.bytes, sizeof profile.colors);
    [colorUndo removeLastObject];
    [self changed];
}

- (void)changed {
    dirty = YES;
    [self repaint];
    [self scheduleSave];
    [self setStatus:T(@"Prévia salva no computador. Clique em Aplicar no teclado para enviar.", @"Preview saved on this Mac. Click Apply to keyboard to send it.")];
}

- (void)paint:(BOOL)all {
    unsigned color;
    if (![self tryColor:&color]) return;
    if (!all && !selected.count) { [self setStatus:T(@"Marque teclas com ⌘ + clique.", @"Select keys with ⌘ + click.")]; return; }
    [self rememberColors];
    if (all) for (int i = 0; i < F75_KEY_COUNT; i++) profile.colors[f75_keys[i].index] = (int)color;
    else [selected enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { self->profile.colors[i] = (int)color; }];
    [selected removeAllIndexes];
    [self changed];
}

- (void)preset:(int)p {
    [self rememberColors];
    for (int i = 0; i < F75_KEY_COUNT; i++) {
        const f75_key *k = &f75_keys[i];
        double t = fmax(0, fmin(1, k->x / 580.0));
        int a = p == 1 ? 0xff785c : p == 2 ? 0x64efcf : 0x89f0ce, b = p == 1 ? 0x985cf9 : p == 2 ? 0x8f70ff : 0x89f0ce;
        int r = (int)(((a >> 16) & 255) * (1 - t) + ((b >> 16) & 255) * t), g = (int)(((a >> 8) & 255) * (1 - t) + ((b >> 8) & 255) * t), bl = (int)((a & 255) * (1 - t) + (b & 255) * t);
        BOOL wasd = !strcmp(k->name, "W") || !strcmp(k->name, "A") || !strcmp(k->name, "S") || !strcmp(k->name, "D");
        profile.colors[k->index] = p == 3 ? (wasd ? 0x89f0ce : 0x232b38) : (r << 16) | (g << 8) | bl;
    }
    [self changed];
}

- (void)applyColors {
    uint8_t p[8][F75_PACKET];
    if (f75_custom(p, profile.colors, profile.brightness)) return;
    [self execute:[self sendWork:[NSData dataWithBytes:p length:sizeof p]] success:^{
        self->dirty = NO; self->rgbOff = NO; self->profile.light_mode = F75_LIGHT_CUSTOM; [self saveLocal]; [self repaint];
        [self setStatus:T(@"Cores enviadas ao teclado F75.", @"Colors sent to the F75 keyboard.")];
    } sent:NO completion:nil];
}

- (void)toggleRgb:(BOOL)off {
    uint8_t p[8][F75_PACKET];
    if (f75_custom(p, profile.colors, off ? 0 : profile.brightness)) return;
    [self execute:[self sendWork:[NSData dataWithBytes:p length:sizeof p]] success:^{
        self->rgbOff = off; self->dirty = NO; self->profile.light_mode = off ? F75_LIGHT_OFF : F75_LIGHT_CUSTOM; [self saveLocal]; [self updateApply];
        [self setStatus:off ? T(@"RGB das teclas desligado. Suas cores continuam salvas no computador.", @"Key RGB off. Your colors remain saved on this Mac.") : T(@"Suas cores foram restauradas no teclado.", @"Your colors were restored on the keyboard.")];
    } sent:NO completion:nil];
}

#pragma mark Macros

- (void)showEvents {
    if (!macroText) return;
    char *json = f75_macro_serialize(events, eventCount);
    macroText.string = eventCount ? [NSString stringWithUTF8String:json] : @"[]";
    free(json);
}

- (void)startMacroRecording {
    eventCount = 0; [macroHeld removeAllIndexes]; macroRecording = YES; macroClock = CFAbsoluteTimeGetCurrent();
    [self showEvents];
    macroCapture.recording = YES;
    macroCapture.text = T(@"GRAVANDO — pressione e solte as teclas nesta área", @"RECORDING — press and release keys in this area");
    [window makeFirstResponder:macroCapture];
    [self setStatus:T(@"Gravando até 60 eventos. As teclas são capturadas somente nesta caixa.", @"Recording up to 60 events. Keys are captured only in this box.")];
}

- (int)elapsed {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int ms = (int)((now - macroClock) * 1000);
    macroClock = now;
    return ms < 10 ? 10 : ms;
}

- (void)recordKey:(unsigned short)keyCode down:(BOOL)down {
    if (!macroRecording) return;
    int code = f75_hid_usage_from_mac_keycode(keyCode);
    if (code <= 0) return;
    if (down) {
        if ([macroHeld containsIndex:keyCode] || eventCount + (int)macroHeld.count + 2 > F75_MAX_MACRO_EVENTS) return;
        [macroHeld addIndex:keyCode];
        events[eventCount++] = (f75_macro_event){code, 0, [self elapsed]};
    } else {
        if (![macroHeld containsIndex:keyCode] || eventCount >= F75_MAX_MACRO_EVENTS) return;
        [macroHeld removeIndex:keyCode];
        events[eventCount++] = (f75_macro_event){code, 1, [self elapsed]};
    }
    [self showEvents];
}

- (void)stopMacroRecording:(BOOL)report {
    if (!macroRecording) return;
    macroRecording = NO;
    [macroHeld enumerateIndexesUsingBlock:^(NSUInteger keyCode, BOOL *stop) {
        int code = f75_hid_usage_from_mac_keycode((int)keyCode);
        if (code > 0 && self->eventCount < F75_MAX_MACRO_EVENTS) self->events[self->eventCount++] = (f75_macro_event){code, 1, 10};
    }];
    [macroHeld removeAllIndexes];
    [self showEvents];
    if (macroCapture) {
        macroCapture.recording = NO;
        macroCapture.text = [NSString stringWithFormat:@"%@%d%@", T(@"Gravação parada · ", @"Recording stopped · "), eventCount, T(@" eventos", @" events")];
    }
    if (report) [self setStatus:T(@"Sequência gravada. Confira os eventos e envie para testar.", @"Sequence recorded. Review the events and send it to test.")];
}

- (void)sendMacro {
    NSData *json = [macroText.string dataUsingEncoding:NSUTF8StringEncoding];
    f75_macro_event parsed[F75_MAX_MACRO_EVENTS]; int count; char err[160]; const char *why = NULL;
    uint8_t p[3][F75_PACKET];
    if (f75_macro_parse(json.bytes, json.length, parsed, F75_MAX_MACRO_EVENTS, &count, err, sizeof err)) why = err;
    else if (f75_macro(p, triggerKeys[trigger.indexOfSelectedItem].intValue, parsed, count, &why) == 0) why = NULL;
    if (why) { [self setStatus:[NSString stringWithFormat:@"%@%s", T(@"Macro inválida: ", @"Invalid macro: "), why]]; return; }
    memcpy(events, parsed, sizeof(f75_macro_event) * (size_t)count); eventCount = count;
    [self execute:[self sendWork:[NSData dataWithBytes:p length:sizeof p]] success:nil sent:YES completion:nil];
}

#pragma mark Profiles

- (void)loadProfile {
    NSData *data = [NSData dataWithContentsOfFile:statePath];
    if (!data) return;
    f75_profile loaded; char err[160]; const char *why = NULL;
    if (data.length > 131072 || f75_profile_parse(data.bytes, data.length, &loaded, err, sizeof err)) why = data.length > 131072 ? "File too large" : err;
    else if (f75_profile_validate(&loaded, &why) == 0) { profile = loaded; language = [NSString stringWithUTF8String:profile.language]; return; }
    lastStatus = [NSString stringWithFormat:@"Perfil local não carregado / Local profile not loaded: %s", why];
}

- (void)syncLanguage { strlcpy(profile.language, language.UTF8String, sizeof profile.language); }

- (void)scheduleSave {
    if (suppressSave) return;
    [saveTimer invalidate];
    saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(saveTimerFired) userInfo:nil repeats:NO];
}
- (void)saveTimerFired { [self saveLocal]; }

- (BOOL)saveLocal {
    [saveTimer invalidate]; saveTimer = nil;
    if (suppressSave) return YES;
    [self syncLanguage];
    const char *why;
    if (f75_profile_validate(&profile, &why)) { [self setStatus:[NSString stringWithFormat:@"%@%s", T(@"Falha ao salvar no computador: ", @"Could not save on this Mac: "), why]]; return NO; }
    char *json = f75_profile_serialize(&profile);
    NSData *data = [NSData dataWithBytesNoCopy:json length:strlen(json) freeWhenDone:YES];
    NSError *error;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:&error] || ![data writeToFile:statePath options:NSDataWritingAtomic error:&error]) {
        [self setStatus:[NSString stringWithFormat:@"%@%@", T(@"Falha ao salvar no computador: ", @"Could not save on this Mac: "), error.localizedDescription]];
        return NO;
    }
    NSString *backup = [statePath stringByAppendingString:@".bak"];
    [fm removeItemAtPath:backup error:NULL];
    [fm copyItemAtPath:statePath toPath:backup error:NULL];
    return YES;
}

- (void)exportProfile {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"F75-profile.json";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"json"];
#pragma clang diagnostic pop
    if ([panel runModal] != NSModalResponseOK) return;
    [self syncLanguage];
    const char *why;
    if (f75_profile_validate(&profile, &why)) { [self setStatus:@(why)]; return; }
    char *json = f75_profile_serialize(&profile);
    NSError *error;
    BOOL ok = [[NSData dataWithBytesNoCopy:json length:strlen(json) freeWhenDone:YES] writeToURL:panel.URL options:NSDataWritingAtomic error:&error];
    [self setStatus:ok ? T(@"Perfil exportado.", @"Profile exported.") : error.localizedDescription];
}

- (void)importProfile {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"json"];
#pragma clang diagnostic pop
    if ([panel runModal] != NSModalResponseOK) return;
    NSData *data = [NSData dataWithContentsOfURL:panel.URL];
    f75_profile p; char err[160]; const char *why = NULL;
    if (!data || data.length > 131072) why = "File too large";
    else if (f75_profile_parse(data.bytes, data.length, &p, err, sizeof err)) why = err;
    else f75_profile_validate(&p, &why);
    if (why) { [self setStatus:[NSString stringWithFormat:@"%@%s", T(@"Não foi possível importar: ", @"Could not import: "), why]]; return; }
    p.keep_in_tray = profile.keep_in_tray;
    profile = p;
    language = [NSString stringWithUTF8String:p.language];
    dirty = YES;
    [self saveLocal];
    [self buildMenu];
    [self build];
    [self setStatus:T(@"Perfil carregado na prévia.", @"Profile loaded into preview.")];
}

#pragma mark Device

- (void)setStatus:(NSString *)s { lastStatus = s ?: @""; status.stringValue = lastStatus; }

- (void)reportError:(NSString *)message {
    [self setStatus:[NSString stringWithFormat:@"%@%@", T(@"Não foi possível concluir: ", @"Could not complete: "), message]];
    NSString *log = [dataDir stringByAppendingPathComponent:@"errors.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:log error:NULL];
    if (attributes.fileSize > 524288) [NSFileManager.defaultManager removeItemAtPath:log error:NULL];
    if (![NSFileManager.defaultManager fileExistsAtPath:log]) [NSFileManager.defaultManager createFileAtPath:log contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:log];
    [h seekToEndOfFile];
    [h writeData:[[NSString stringWithFormat:@"%@ %@\n", [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]], message] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

- (BOOL (^)(NSError **))sendWork:(NSData *)packets {
    return ^BOOL(NSError **error) {
        return [[F75HID shared] sendPackets:(const uint8_t (*)[F75_PACKET])packets.bytes count:(int)(packets.length / F75_PACKET) error:error];
    };
}

// One USB operation at a time, off the main thread; the UI is disabled meanwhile, like Execute() on Windows.
- (BOOL)execute:(BOOL (^)(NSError **))work success:(void (^)(void))success sent:(BOOL)sent completion:(void (^)(BOOL ok, NSError *error))completion {
    if (busy) return NO;
    busy = YES;
    [self setEnabled:NO];
    [self setStatus:T(@"Comunicando com o F75…", @"Communicating with F75…")];
    dispatch_async(io, ^{
        NSError *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->busy = NO;
            [self setEnabled:YES];
            if (ok) {
                if (success) success();
                if (sent) [self setStatus:T(@"Pacotes enviados ao F75. Confira o resultado no teclado.", @"Packets sent to F75. Check the result on your keyboard.")];
                if ([F75HID shared].lastReplyMissing && !self->quitting) {
                    [self setStatus:T(@"Enviado, mas o F75 não respondeu. Veja o aviso.", @"Sent, but the F75 did not answer. See the alert.")];
                    [self usbProblem:T(@"O macOS aceitou o envio, mas o teclado não respondeu. Se as cores não mudaram, ligue o cabo direto no Mac (sem hub), feche outros apps do teclado e tente de novo.", @"macOS accepted the write but the keyboard did not answer. If the colors did not change, plug the cable straight into the Mac (no hub), close other keyboard apps and try again.")];
                }
            } else {
                [self setStatus:[NSString stringWithFormat:@"%@%@", T(@"Operação não concluída: ", @"Operation incomplete: "), error.localizedDescription ?: @"?"]];
                if (!completion && !self->quitting) [self usbProblem:error.localizedDescription ?: @"?"];
            }
            [self updateApply];
            if (completion) completion(ok, error);
        });
    });
    return YES;
}

- (void)refresh:(BOOL)showMessage {
    if (busy || refreshing) return;
    refreshing = YES;
    dispatch_async(io, ^{
        F75Status *s = [[F75HID shared] readStatusSnapshot];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->refreshing = NO;
            self->snapshot = s;
            self->statusStale = NO;
            [self updateDeviceLabels];
            [self updatePolling];
            if (showMessage) [self setStatus:T(@"Consulta atualizada. Bateria é o valor informado pelo teclado; pelo cabo pode permanecer em 100%.", @"Status updated. Battery is the value reported by the keyboard; it may remain at 100% over USB.")];
        });
    });
}

// No periodic USB polling: over the cable the battery always reads 100%. Only a visible wireless link is re-read every 30 s.
- (void)updatePolling {
    BOOL wireless = [snapshot.transport isEqualToString:@"2.4 GHz"];
    if (wireless && [self uiVisible] && !suppressSave) {
        if (!statusTimer) statusTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(pollTick) userInfo:nil repeats:YES];
    } else { [statusTimer invalidate]; statusTimer = nil; }
}
- (void)pollTick { if ([self uiVisible] && !busy && !refreshing) [self refresh:NO]; }

- (void)updateDeviceLabels {
    NSString *transport = T(@"Consultando conexão…", @"Checking connection…"), *battery = T(@"Bateria: aguardando leitura", @"Battery: waiting for reading");
    if (snapshot) {
        NSString *t = snapshot.transport;
        if ([t isEqualToString:@"USB"]) transport = snapshot.responding ? @"USB · F75" : T(@"USB detectado · sem resposta", @"USB detected · no response");
        else if ([t isEqualToString:@"2.4 GHz"]) transport = T(@"Sem fio 2,4 GHz · F75", @"Wireless 2.4 GHz · F75");
        else if ([t isEqualToString:@"Receiver"]) transport = T(@"Receptor 2,4 GHz · sem resposta", @"2.4 GHz receiver · no response");
        else if ([t isEqualToString:@"Bluetooth"]) transport = T(@"Bluetooth · detectado", @"Bluetooth · detected");
        else transport = T(@"F75 não detectado", @"F75 not detected");
        battery = snapshot.battery >= 0 ? [NSString stringWithFormat:@"%@%d%%", T(@"Bateria informada: ", @"Reported battery: "), snapshot.battery] : T(@"Bateria: indisponível", @"Battery: unavailable");
    }
    connectionText.stringValue = transport;
    batteryText.stringValue = battery;
    batteryText.toolTip = snapshot.detail;
    if (deviceStatusText) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss";
        deviceStatusText.stringValue = snapshot ? [NSString stringWithFormat:@"%@\n%@\n%@%@", transport, battery, T(@"Atualizado às ", @"Updated at "), [f stringFromDate:snapshot.checkedAt]] : [NSString stringWithFormat:@"%@\n%@", transport, battery];
        deviceStatusText.toolTip = snapshot.detail;
    }
}

// Shown when a USB operation fails or goes unanswered; the diagnostic is what is needed to fix the Mac transport.
- (void)usbProblem:(NSString *)text {
    NSAlert *alert = [NSAlert new];
    alert.messageText = T(@"O F75 não confirmou o envio", @"The F75 did not confirm");
    alert.informativeText = [text stringByAppendingString:T(@"\n\n\"Copiar diagnóstico\" testa todas as formas de envio e copia o resultado; cole-o na conversa de suporte.", @"\n\n\"Copy diagnostics\" tests every send method and copies the result; paste it into the support chat.")];
    [alert addButtonWithTitle:T(@"Copiar diagnóstico", @"Copy diagnostics")];
    [alert addButtonWithTitle:@"OK"];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self copyDiagnostics];
}

- (void)copyDiagnostics {
    if (busy) return;
    busy = YES;
    [self setEnabled:NO];
    [self setStatus:T(@"Testando o USB… (alguns segundos)", @"Testing USB… (a few seconds)")];
    dispatch_async(io, ^{
        NSString *report = [NSString stringWithFormat:@"F75 Studio 1.0 (macOS %@)\n%@", NSProcessInfo.processInfo.operatingSystemVersionString, [[F75HID shared] diagnosticReport]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->busy = NO;
            [self setEnabled:YES];
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:report forType:NSPasteboardTypeString];
            [self setStatus:T(@"Diagnóstico copiado. Cole na conversa de suporte.", @"Diagnostics copied. Paste it into the support chat.")];
        });
    });
}

- (void)exportDiagnostics {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"F75-diagnostics.txt";
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *url = panel.URL;
    if (busy) return;
    dispatch_async(io, ^{
        F75Status *d = [[F75HID shared] readStatusSnapshot];
        NSMutableString *raw = [NSMutableString new];
        for (NSUInteger i = 0; i < d.raw.length; i++) [raw appendFormat:i ? @"-%02X" : @"%02X", ((const uint8_t *)d.raw.bytes)[i]];
        NSString *text = [NSString stringWithFormat:@"F75 Studio 1.0 final (macOS %@)\nUTC: %@\nTransport: %@\nResponding: %@\nReported battery: %@\nDetail: %@\nRaw: %@\n\n%@",
                          NSProcessInfo.processInfo.operatingSystemVersionString, [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]], d.transport, d.responding ? @"True" : @"False",
                          d.battery >= 0 ? [NSString stringWithFormat:@"%d%%", d.battery] : @"unavailable", d.detail, d.raw ? raw : @"unavailable", [[F75HID shared] diagnosticReport]];
        NSError *error;
        BOOL ok = [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->snapshot = d; [self updateDeviceLabels];
            [self setStatus:ok ? T(@"Diagnóstico exportado.", @"Diagnostics exported.") : error.localizedDescription];
        });
    });
}

#pragma mark Measurement (--measure)

static void Usage(double *cpuMs, double *footprintMiB) {
    struct rusage r;
    getrusage(RUSAGE_SELF, &r);
    *cpuMs = (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1000.0 + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1000.0;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    *footprintMiB = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint / 1048576.0 : -1;
}

// Same protocol as --measure on Windows: 3 s warm-up, 5 s idle with the window, then 5 s idle with the UI released.
// "Memory" in Activity Monitor is the same phys_footprint number.
- (void)runMeasurement {
    suppressSave = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        __block double cpu0, mem;
        Usage(&cpu0, &mem);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            double cpu1, mem1;
            Usage(&cpu1, &mem1);
            printf("Window open, idle 5 seconds after 3-second warm-up: CPU ms=%.1f; footprint MiB=%.1f\n", cpu1 - cpu0, mem1);
            fflush(stdout);
            [self->window orderOut:nil];
            [self releaseUI];
            [[F75HID shared] stopWatching];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                double cpu2, mem2;
                Usage(&cpu2, &mem2);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    double cpu3, mem3;
                    Usage(&cpu3, &mem3);
                    printf("Background (UI released), idle 5 seconds: CPU ms=%.1f; footprint MiB=%.1f\n", cpu3 - cpu2, mem3);
                    fflush(stdout);
                    [self quitWithoutSending];
                });
            });
        });
    });
}
@end

static void PrintLine(const char *line) { printf("%s\n", line); }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL measure = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self-test")) { int failures = f75_self_test(PrintLine); printf("%d failure(s)\n", failures); return failures ? 1 : 0; }
            if (!strcmp(argv[i], "--diagnose")) {
                printf("F75 Studio 1.0 (macOS %s)\n%s", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String, [[F75HID shared] diagnosticReport].UTF8String);
                return 0;
            }
            if (!strcmp(argv[i], "--low-latency")) {
                uint8_t p[1][F75_PACKET]; NSError *error;
                f75_response_time(p[0], 1);
                if (![[F75HID shared] sendPackets:p count:1 error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
                printf("Response tier 1 packet sent; physical latency not measured.\n");
                return 0;
            }
            if (!strcmp(argv[i], "--measure")) measure = YES;
        }
        NSApplication *app = [NSApplication sharedApplication];
        F75Studio *studio = [F75Studio new];
        studio.measure = measure;
        app.delegate = studio;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
