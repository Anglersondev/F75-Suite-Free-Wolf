// Same rules as Device.cs: configuration only through the wired 1A2C:A073 vendor interface (FF02:0002, 64-byte reports
// plus report ID 0), the shared 8FFF receiver only for the 0E status query, Bluetooth only identified by name.
// Devices are opened per operation and closed right after, like the Windows build; nothing stays open while idle.
#import "F75HID.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#include <unistd.h>

@implementation F75Status
@end

typedef struct {
    uint8_t buffer[128];   // IOKit writes each input report here
    uint8_t reply[128];
    int replyLength;
    BOOL got;
} F75Input;

static void F75InputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {
    F75Input *input = (F75Input *)context;
    if (result != kIOReturnSuccess || length <= 0 || input->got) return;
    if (length > (CFIndex)sizeof input->reply) length = sizeof input->reply;
    int offset = f75_status_offset(report, (int)length);
    if (offset < 0) return;
    memcpy(input->reply, report + offset, (size_t)length - (size_t)offset);
    input->replyLength = (int)length - offset;
    input->got = YES;
}

static NSError *F75Error(NSString *message) {
    return [NSError errorWithDomain:@"F75Studio" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static int IntProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}

static NSDictionary *Match(int product) {
    return @{@kIOHIDVendorIDKey: @(F75_VID), @kIOHIDProductIDKey: @(product),
             @kIOHIDDeviceUsagePageKey: @(F75_USAGE_PAGE), @kIOHIDDeviceUsageKey: @(F75_USAGE)};
}

// An open, run-loop-scheduled F75 interface for the length of one operation.
@interface F75Open : NSObject {
@public
    IOHIDDeviceRef device;
    F75Input *input;
    BOOL statusOnly;
    IOOptionBits options;
}
@end

static CFStringRef const F75RunLoopMode = CFSTR("F75StudioHID");

@implementation F75Open
- (void)dealloc {
    if (device) {
        IOHIDDeviceRegisterInputReportCallback(device, input->buffer, sizeof input->buffer, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), F75RunLoopMode);
        IOHIDDeviceClose(device, options);
        CFRelease(device);
    }
    free(input);
}
@end

@implementation F75HID {
    IOHIDManagerRef watcher;
    NSUInteger changeGeneration;
}

+ (instancetype)shared {
    static F75HID *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [F75HID new]; });
    return shared;
}

#pragma mark Plug / unplug

static void F75DeviceEvent(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge F75HID *)context deviceEvent];
}

- (void)deviceEvent {
    // Arrival/removal come in bursts (one per interface); refresh once 1.5 s after the last one.
    NSUInteger generation = ++changeGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->changeGeneration && self.devicesChanged) self.devicesChanged();
    });
}

- (void)startWatching {
    if (watcher) return;
    watcher = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    // A hub may expose the device before all of its HID collections are ready.
    // Watch the VID/PID, then let candidates: select the safe vendor interface.
    IOHIDManagerSetDeviceMatchingMultiple(watcher, (__bridge CFArrayRef)@[
        @{@kIOHIDVendorIDKey: @(F75_VID), @kIOHIDProductIDKey: @(F75_PID)},
        @{@kIOHIDVendorIDKey: @(F75_VID), @kIOHIDProductIDKey: @(F75_RECEIVER_PID)}]);
    IOHIDManagerRegisterDeviceMatchingCallback(watcher, F75DeviceEvent, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(watcher, F75DeviceEvent, (__bridge void *)self);
    // Scheduling without IOHIDManagerOpen: notifications only, no device is opened.
    IOHIDManagerScheduleWithRunLoop(watcher, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

- (void)stopWatching {
    if (!watcher) return;
    IOHIDManagerRegisterDeviceMatchingCallback(watcher, NULL, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(watcher, NULL, NULL);
    IOHIDManagerUnscheduleFromRunLoop(watcher, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(watcher);
    watcher = NULL;
    changeGeneration++;
}

#pragma mark Open / transfer

- (NSArray *)devicesMatching:(id)matching {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if ([matching isKindOfClass:[NSArray class]]) IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matching);
    else IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)matching);
    // A single timed-out run-loop pass is not proof that enumeration finished.
    // Give interfaces behind a hub time to arrive before copying the device set.
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), F75RunLoopMode);
    for (int i = 0; i < 20; i++) CFRunLoopRunInMode(F75RunLoopMode, 0.01, false);
    CFSetRef set = IOHIDManagerCopyDevices(manager);
    NSArray *devices = set ? [(__bridge NSSet *)set allObjects] : @[];
    if (set) CFRelease(set);
    IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), F75RunLoopMode);
    CFRelease(manager);
    return devices;
}

static NSString *ReturnText(IOReturn r) {
    if (r == (IOReturn)0xe00002e2) return @"0xE00002E2 (sem permissão / not permitted: Ajustes do Sistema > Privacidade e Segurança > Monitoramento de Entrada / Input Monitoring)";
    if (r == (IOReturn)0xe00002c5) return @"0xE00002C5 (em uso por outro app / exclusive access by another app)";
    if (r == (IOReturn)0xe00002d6) return @"0xE00002D6 (tempo esgotado / timeout)";
    return [NSString stringWithFormat:@"0x%08X", (unsigned)r];
}

static BOOL HasVendorUsage(IOHIDDeviceRef device) {
    if (IntProperty(device, CFSTR("PrimaryUsagePage")) == F75_USAGE_PAGE) return YES;
    NSArray *pairs = (__bridge NSArray *)IOHIDDeviceGetProperty(device, CFSTR("DeviceUsagePairs"));
    for (NSDictionary *pair in pairs) if ([pair[@"DeviceUsagePage"] intValue] == F75_USAGE_PAGE) return YES;
    return NO;
}

// Every 1A2C interface that can take 64-byte reports, best first: the FF02 vendor interface of A073, then any other
// FF02 interface (some boards change PID in Mac mode), then any 1A2C interface with 64-byte output reports.
// Keyboard/mouse interfaces have 1-byte (LED) output reports and are never opened.
- (NSArray *)candidates:(BOOL)receiver {
    NSMutableArray *scored = [NSMutableArray new];
    for (id object in [self devicesMatching:@{@kIOHIDVendorIDKey: @(F75_VID)}]) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
        int pid = IntProperty(device, CFSTR(kIOHIDProductIDKey)), output = IntProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
        if ((pid == F75_RECEIVER_PID) != receiver) continue;
        BOOL vendor = HasVendorUsage(device);
        if (!vendor && output < 64) continue;
        if (output && output < 64) continue;
        [scored addObject:@[@((vendor ? 4 : 0) + (pid == F75_PID ? 2 : 0) + (output >= 64 ? 1 : 0)), object]];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *devices = [NSMutableArray new];
    for (NSArray *pair in scored) [devices addObject:pair[1]];
    return devices;
}

- (F75Open *)openDevice:(IOHIDDeviceRef)device statusOnly:(BOOL)statusOnly options:(IOOptionBits)options result:(IOReturn *)result {
    *result = IOHIDDeviceOpen(device, options);
    if (*result != kIOReturnSuccess) return nil;
    F75Open *open = [F75Open new];
    open->device = (IOHIDDeviceRef)CFRetain(device);
    open->options = options;
    open->input = calloc(1, sizeof(F75Input));
    open->statusOnly = statusOnly;
    IOHIDDeviceRegisterInputReportCallback(device, open->input->buffer, sizeof open->input->buffer, F75InputReport, open->input);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), F75RunLoopMode);
    return open;
}

// reason receives why no interface could be opened, for the status bar and --diagnose.
- (F75Open *)openReceiver:(BOOL)receiver present:(BOOL *)present reason:(NSString **)reason {
    NSArray *devices = [self candidates:receiver];
    *present = devices.count > 0;
    for (id object in devices) {
        IOReturn result;
        F75Open *open = [self openDevice:(__bridge IOHIDDeviceRef)object statusOnly:receiver options:kIOHIDOptionsTypeNone result:&result];
        if (open) return open;
        if (reason) *reason = [NSString stringWithFormat:@"IOHIDDeviceOpen: %@", ReturnText(result)];
    }
    return nil;
}

- (F75Open *)openReceiver:(BOOL)receiver present:(BOOL *)present {
    return [self openReceiver:receiver present:present reason:NULL];
}

// How the report reaches the keyboard. Windows writes 65 bytes (report ID 0 + 64) with WriteFile; IOKit can express that
// three ways, and which one the F75 firmware accepts on macOS has not been observed yet, so the first one that the
// keyboard answers (status 0E) is kept for the rest of the session.
typedef enum { F75WriteOutput64 = 0, F75WriteOutput65, F75WriteFeature64, F75WriteModes } F75WriteMode;
static F75WriteMode writeMode = F75WriteOutput64;
static BOOL writeModeConfirmed = NO;
static const char *const WriteModeNames[] = {"output id0 64", "output id0 65", "feature id0 64"};

static IOReturn Write(IOHIDDeviceRef device, const uint8_t *packet, F75WriteMode mode) {
    switch (mode) {
    case F75WriteOutput65: return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, F75_PACKET);
    case F75WriteFeature64: return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, packet + 1, F75_PACKET - 1);
    default: return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet + 1, F75_PACKET - 1);
    }
}

- (BOOL)send:(const uint8_t *)packet on:(F75Open *)open mode:(F75WriteMode)mode error:(NSError **)error {
    if (!f75_valid_packet(packet)) { if (error) *error = F75Error(@"Invalid F75 packet"); return NO; }
    if (open->statusOnly) {
        BOOL empty = packet[5] == 0x0e;
        for (int i = 6; i < F75_PACKET && empty; i++) if (packet[i]) empty = NO;
        if (!empty) { if (error) *error = F75Error(@"Receiver permits only status command 0E"); return NO; }
    }
    IOReturn result = Write(open->device, packet, mode);
    if (result != kIOReturnSuccess) {
        if (error) *error = F75Error([NSString stringWithFormat:@"Falha na escrita USB / USB write failed (%s): %@", WriteModeNames[mode], ReturnText(result)]);
        return NO;
    }
    usleep(20000);
    return YES;
}

- (BOOL)send:(const uint8_t *)packet on:(F75Open *)open error:(NSError **)error {
    return [self send:packet on:open mode:writeMode error:error];
}

- (BOOL)waitForStatus:(F75Open *)open {
    // Up to 8 reports, giving up after 250 ms of silence, as in Device.cs.
    for (int i = 0; i < 8 && !open->input->got; i++) {
        SInt32 result = CFRunLoopRunInMode(F75RunLoopMode, 0.25, true);
        if (result == kCFRunLoopRunTimedOut || result == kCFRunLoopRunFinished) break;
    }
    if (!open->input->got) {
        // Some devices only answer a GET_REPORT on the control pipe.
        uint8_t report[128]; CFIndex length = sizeof report;
        if (IOHIDDeviceGetReport(open->device, kIOHIDReportTypeInput, 0, report, &length) == kIOReturnSuccess) F75InputReport(open->input, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0, report, length);
    }
    return open->input->got;
}

- (NSData *)statusOn:(F75Open *)open error:(NSError **)error {
    uint8_t packet[F75_PACKET];
    f75_packet(packet, 0x0e, NULL, 0);
    NSError *firstWriteError = nil;
    BOOL wrote = NO;
    // Until a mode is confirmed by a reply, try each one; afterwards only the confirmed mode.
    for (int mode = writeModeConfirmed ? writeMode : 0; mode < F75WriteModes; mode++) {
        NSError *e = nil;
        open->input->got = NO;
        if ([self send:packet on:open mode:(F75WriteMode)mode error:&e]) {
            if (!wrote) { wrote = YES; if (!writeModeConfirmed) writeMode = (F75WriteMode)mode; }
            if ([self waitForStatus:open]) { writeMode = (F75WriteMode)mode; writeModeConfirmed = YES; break; }
        } else if (!firstWriteError) firstWriteError = e;
        if (writeModeConfirmed) break;
    }
    if (!wrote) { if (error) *error = firstWriteError; return nil; }
    if (!open->input->got) { if (error) *error = F75Error(@"F75 não respondeu à consulta / No F75 status response."); return nil; }
    return [NSData dataWithBytes:open->input->reply length:(NSUInteger)open->input->replyLength];
}

// No reply on a shared open: another process (the vendor's own app, a key remapper) may be holding the interface.
// Reopen it exclusively once; if that is refused or still silent, keep the shared open.
// Returns NO only when the interface could not be reopened at all (*openRef is then nil).
- (BOOL)seizeIfSilent:(F75Open *__strong *)openRef {
    IOHIDDeviceRef device = (IOHIDDeviceRef)CFRetain((*openRef)->device);
    BOOL statusOnly = (*openRef)->statusOnly;
    *openRef = nil;   // closes the shared open before asking for exclusive access
    IOReturn result;
    F75Open *seized = [self openDevice:device statusOnly:statusOnly options:kIOHIDOptionsTypeSeizeDevice result:&result];
    if (seized && [self statusOn:seized error:NULL]) *openRef = seized;
    else {
        seized = nil;
        *openRef = [self openDevice:device statusOnly:statusOnly options:kIOHIDOptionsTypeNone result:&result];
    }
    CFRelease(device);
    return *openRef != nil;
}

static NSString *const F75Unavailable = @"F75 USB (1A2C:A073) indisponível / unavailable. Conecte por cabo e feche outros apps do teclado / Connect by cable and close other keyboard apps.";

- (NSError *)unavailable:(NSString *)reason {
    return F75Error(reason ? [NSString stringWithFormat:@"%@ [%@]", F75Unavailable, reason] : F75Unavailable);
}

// Errors are created outside the autorelease pools below: an NSError autoreleased inside a pool is freed when the pool
// drains, and the caller would then read a dangling pointer (the 1.0 crash on every failed USB operation).
- (BOOL)sendPackets:(const uint8_t (*)[F75_PACKET])packets count:(int)count error:(NSError **)error {
    NSError *failure = nil;
    BOOL ok = NO;
    _lastReplyMissing = NO;
    @autoreleasepool {
        BOOL present; NSString *reason = nil; NSError *e = nil;
        F75Open *open = [self openReceiver:NO present:&present reason:&reason];
        if (!open) failure = [self unavailable:reason];
        else {
            // The status reply is the least proven part on macOS; a missing reply is not a reason to skip the write.
            // A failed write is: it means the interface does not accept output reports.
            BOOL writeFailed = NO;
            if (![self statusOn:open error:&e]) {
                writeFailed = [e.localizedDescription hasPrefix:@"Falha na escrita"];
                if (!writeFailed && ![self seizeIfSilent:&open]) failure = [self unavailable:@"reopen failed"];
            }
            if (!failure && writeFailed) failure = e;
            if (!failure) {
                ok = YES;
                _lastReplyMissing = !open->input->got;
                for (int i = 0; i < count && ok; i++) if (![self send:packets[i] on:open error:&e]) { ok = NO; failure = e; }
            }
        }
    }
    if (!ok && error) *error = failure;
    return ok;
}

- (NSData *)queryStatus:(NSError **)error {
    NSError *failure = nil;
    NSData *raw = nil;
    @autoreleasepool {
        BOOL present; NSString *reason = nil; NSError *e = nil;
        F75Open *open = [self openReceiver:NO present:&present reason:&reason];
        if (!open) failure = [self unavailable:present ? reason : nil];
        else if (!(raw = [self statusOn:open error:&e])) {
            if ([self seizeIfSilent:&open] && open->input->got) raw = [NSData dataWithBytes:open->input->reply length:(NSUInteger)open->input->replyLength];
            else failure = e;
        }
    }
    if (!raw && error) *error = failure;
    return raw;
}

static NSString *Hex(const uint8_t *bytes, NSUInteger length) {
    NSMutableString *s = [NSMutableString new];
    for (NSUInteger i = 0; i < length; i++) [s appendFormat:i ? @" %02X" : @"%02X", bytes[i]];
    return s;
}

static NSString *Describe(IOHIDDeviceRef device) {
    NSMutableString *s = [NSMutableString new];
    for (NSString *key in @[@kIOHIDProductIDKey, @kIOHIDProductKey, @kIOHIDTransportKey, @"PrimaryUsagePage", @"PrimaryUsage", @kIOHIDMaxInputReportSizeKey, @kIOHIDMaxOutputReportSizeKey, @"MaxFeatureReportSize", @"LocationID"]) {
        id value = (__bridge id)IOHIDDeviceGetProperty(device, (__bridge CFStringRef)key);
        if ([value isKindOfClass:[NSNumber class]] && ([key containsString:@"Usage"] || [key containsString:@"ID"])) value = [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
        [s appendFormat:@"  %@: %@\n", key, value ?: @"-"];
    }
    NSArray *pairs = (__bridge NSArray *)IOHIDDeviceGetProperty(device, CFSTR("DeviceUsagePairs"));
    for (NSDictionary *pair in pairs) [s appendFormat:@"  usage pair: 0x%04X:0x%04X\n", [pair[@"DeviceUsagePage"] unsignedIntValue], [pair[@"DeviceUsage"] unsignedIntValue]];
    return s;
}

- (NSString *)diagnosticReport {
    NSMutableString *out = [NSMutableString new];
    @autoreleasepool {
        NSArray *all = [self devicesMatching:@{@kIOHIDVendorIDKey: @(F75_VID)}];
        [out appendFormat:@"macOS %@\n", [NSProcessInfo processInfo].operatingSystemVersionString];
        [out appendFormat:@"HID devices with VID 1A2C: %lu\n", (unsigned long)all.count];
        for (id object in all) [out appendFormat:@"-\n%@", Describe((__bridge IOHIDDeviceRef)object)];
        [out appendFormat:@"F75 vendor interfaces (A073 FF02:0002): %lu\n", (unsigned long)[self devicesMatching:Match(F75_PID)].count];
        NSArray *candidates = [self candidates:NO];
        [out appendFormat:@"Config candidates: %lu\n", (unsigned long)candidates.count];
        uint8_t packet[F75_PACKET];
        f75_packet(packet, 0x0e, NULL, 0);
        for (int seize = 0; seize < 2; seize++) for (id object in candidates) {
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
            IOReturn result;
            F75Open *open = [self openDevice:device statusOnly:NO options:seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone result:&result];
            [out appendFormat:@"PID 0x%04X usage 0x%04X %@: open %@\n", IntProperty(device, CFSTR(kIOHIDProductIDKey)), IntProperty(device, CFSTR("PrimaryUsagePage")), seize ? @"seize" : @"shared", open ? @"ok" : ReturnText(result)];
            if (!open) continue;
            for (int mode = 0; mode < F75WriteModes; mode++) {
                open->input->got = NO;
                IOReturn w = Write(device, packet, (F75WriteMode)mode);
                BOOL replied = w == kIOReturnSuccess && [self waitForStatus:open];
                [out appendFormat:@"  write %s: %@; reply: %@\n", WriteModeNames[mode], w == kIOReturnSuccess ? @"ok" : ReturnText(w), replied ? Hex(open->input->reply, (NSUInteger)open->input->replyLength) : @"none"];
            }
        }
    }
    return out;
}

#pragma mark Status snapshot

static F75Status *Snapshot(NSString *transport, BOOL responding, int battery, NSString *detail, NSData *raw) {
    F75Status *s = [F75Status new];
    s.transport = transport; s.responding = responding; s.battery = battery; s.detail = detail; s.raw = raw; s.checkedAt = [NSDate date];
    return s;
}

- (BOOL)hasBrandedBluetooth {
    NSArray *matching = @[@{@kIOHIDTransportKey: @"Bluetooth"}, @{@kIOHIDTransportKey: @"Bluetooth Low Energy"}];
    for (id object in [self devicesMatching:matching]) {
        CFTypeRef value = IOHIDDeviceGetProperty((__bridge IOHIDDeviceRef)object, CFSTR(kIOHIDProductKey));
        if (!value || CFGetTypeID(value) != CFStringGetTypeID()) continue;
        NSString *product = (__bridge NSString *)value;
        for (NSString *drop in @[@" ", @"-", @"_"]) product = [product stringByReplacingOccurrencesOfString:drop withString:@""];
        // Do not infer Bluetooth from a generic name: only the F75's own product string counts.
        if ([product caseInsensitiveCompare:@"FREEWOLFF75"] == NSOrderedSame || [product caseInsensitiveCompare:@"F75"] == NSOrderedSame) return YES;
    }
    return NO;
}

- (F75Status *)readStatusSnapshot {
    @autoreleasepool {
        // USB always wins; the shared receiver is never used for configuration.
        for (int receiver = 0; receiver < 2; receiver++) {
            BOOL present;
            F75Open *open = [self openReceiver:receiver present:&present];
            if (open) {
                NSData *raw = [self statusOn:open error:NULL];
                int battery;
                if (raw && f75_parse_status(raw.bytes, (int)raw.length, &battery) == 0)
                    return Snapshot(receiver ? @"2.4 GHz" : @"USB", YES, battery, @"Resposta recebida / Status response received", raw);
                return Snapshot(receiver ? @"Receiver" : @"USB", NO, -1, receiver ? @"Receptor detectado; teclado não respondeu / Receiver detected; keyboard did not respond" : @"USB detectado; status indisponível / USB detected; status unavailable", nil);
            }
            if (present) return Snapshot(receiver ? @"Receiver" : @"USB", NO, -1, @"Dispositivo detectado, mas interface ocupada ou indisponível / Device detected; interface busy or unavailable", nil);
        }
        if ([self hasBrandedBluetooth]) return Snapshot(@"Bluetooth", NO, -1, @"HID Bluetooth F75 detectado; status e bateria indisponíveis / F75 Bluetooth HID detected; status and battery unavailable", nil);
        return Snapshot(@"Disconnected", NO, -1, @"F75 USB/receptor não detectado ou ocupado; Bluetooth não identificado / F75 USB/receiver unavailable or busy; Bluetooth not identified", nil);
    }
}
@end
