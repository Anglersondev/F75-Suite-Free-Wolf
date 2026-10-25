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
}
@end

static CFStringRef const F75RunLoopMode = CFSTR("F75StudioHID");

@implementation F75Open
- (void)dealloc {
    if (device) {
        IOHIDDeviceRegisterInputReportCallback(device, input->buffer, sizeof input->buffer, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), F75RunLoopMode);
        IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
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
    IOHIDManagerSetDeviceMatchingMultiple(watcher, (__bridge CFArrayRef)@[Match(F75_PID), Match(F75_RECEIVER_PID)]);
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
    // Like hidapi: let the manager deliver its pending matches before copying the device set.
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), F75RunLoopMode);
    for (int i = 0; i < 50 && CFRunLoopRunInMode(F75RunLoopMode, 0.001, false) == kCFRunLoopRunHandledSource; i++) {}
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

// reason receives why no interface could be opened (sizes or IOHIDDeviceOpen result), for the status bar and --diagnose.
- (F75Open *)openReceiver:(BOOL)receiver present:(BOOL *)present reason:(NSString **)reason {
    *present = NO;
    for (id object in [self devicesMatching:Match(receiver ? F75_RECEIVER_PID : F75_PID)]) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
        *present = YES;
        // 64 data bytes each way (65 on Windows, which counts the report ID). A missing property is not a reason to skip.
        int input = IntProperty(device, CFSTR(kIOHIDMaxInputReportSizeKey)), output = IntProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
        if ((input && input < 64) || (output && output < 64)) {
            if (reason) *reason = [NSString stringWithFormat:@"Interface com relatórios de %d/%d bytes / reports of %d/%d bytes", input, output, input, output];
            continue;
        }
        IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
        if (result != kIOReturnSuccess) {
            if (reason) *reason = [NSString stringWithFormat:@"IOHIDDeviceOpen: %@", ReturnText(result)];
            continue;
        }
        F75Open *open = [F75Open new];
        open->device = (IOHIDDeviceRef)CFRetain(device);
        open->input = calloc(1, sizeof(F75Input));
        open->statusOnly = receiver;
        IOHIDDeviceRegisterInputReportCallback(device, open->input->buffer, sizeof open->input->buffer, F75InputReport, open->input);
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), F75RunLoopMode);
        return open;
    }
    return nil;
}

- (F75Open *)openReceiver:(BOOL)receiver present:(BOOL *)present {
    return [self openReceiver:receiver present:present reason:NULL];
}

- (BOOL)send:(const uint8_t *)packet on:(F75Open *)open error:(NSError **)error {
    if (!f75_valid_packet(packet)) { if (error) *error = F75Error(@"Invalid F75 packet"); return NO; }
    if (open->statusOnly) {
        BOOL empty = packet[5] == 0x0e;
        for (int i = 6; i < F75_PACKET && empty; i++) if (packet[i]) empty = NO;
        if (!empty) { if (error) *error = F75Error(@"Receiver permits only status command 0E"); return NO; }
    }
    // Byte 0 is report ID 0: IOKit takes it as a separate argument and the 64 data bytes after it.
    IOReturn result = IOHIDDeviceSetReport(open->device, kIOHIDReportTypeOutput, 0, packet + 1, F75_PACKET - 1);
    if (result != kIOReturnSuccess) {
        if (error) *error = F75Error([NSString stringWithFormat:@"Falha na escrita USB / USB write failed: %@", ReturnText(result)]);
        return NO;
    }
    usleep(20000);
    return YES;
}

- (NSData *)statusOn:(F75Open *)open error:(NSError **)error {
    uint8_t packet[F75_PACKET];
    f75_packet(packet, 0x0e, NULL, 0);
    open->input->got = NO;
    if (![self send:packet on:open error:error]) return nil;
    // Up to 8 reports, giving up after 250 ms of silence, as in Device.cs.
    for (int i = 0; i < 8 && !open->input->got; i++) {
        SInt32 result = CFRunLoopRunInMode(F75RunLoopMode, 0.25, true);
        if (result == kCFRunLoopRunTimedOut || result == kCFRunLoopRunFinished) break;
    }
    if (!open->input->got) { if (error) *error = F75Error(@"F75 não respondeu à consulta / No F75 status response."); return nil; }
    return [NSData dataWithBytes:open->input->reply length:(NSUInteger)open->input->replyLength];
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
    @autoreleasepool {
        BOOL present; NSString *reason = nil; NSError *e = nil;
        F75Open *open = [self openReceiver:NO present:&present reason:&reason];
        if (!open) failure = [self unavailable:reason];
        else {
            // The status reply is the least proven part on macOS; a missing reply is not a reason to skip the write.
            // A failed write is: it means the interface does not accept output reports.
            if (![self statusOn:open error:&e] && [e.localizedDescription hasPrefix:@"Falha na escrita"]) failure = e;
            else {
                ok = YES;
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
        else if (!(raw = [self statusOn:open error:&e])) failure = e;
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
        [out appendFormat:@"HID devices with VID 1A2C: %lu\n", (unsigned long)all.count];
        for (id object in all) [out appendFormat:@"-\n%@", Describe((__bridge IOHIDDeviceRef)object)];
        [out appendFormat:@"F75 vendor interfaces (A073 FF02:0002): %lu\n", (unsigned long)[self devicesMatching:Match(F75_PID)].count];
        BOOL present; NSString *reason = nil;
        F75Open *open = [self openReceiver:NO present:&present reason:&reason];
        if (!open) { [out appendFormat:@"Open: failed%@\n", reason ? [@" — " stringByAppendingString:reason] : @" (no matching interface)"]; return out; }
        [out appendString:@"Open: ok\n"];
        uint8_t packet[F75_PACKET];
        f75_packet(packet, 0x0e, NULL, 0);
        open->input->got = NO;
        IOReturn result = IOHIDDeviceSetReport(open->device, kIOHIDReportTypeOutput, 0, packet + 1, F75_PACKET - 1);
        [out appendFormat:@"SetReport(output, id 0, 64 bytes) 0E: %@\n", result == kIOReturnSuccess ? @"ok" : ReturnText(result)];
        for (int i = 0; i < 8 && !open->input->got; i++) if (CFRunLoopRunInMode(F75RunLoopMode, 0.25, true) != kCFRunLoopRunHandledSource) break;
        [out appendFormat:@"Status reply: %@\n", open->input->got ? Hex(open->input->reply, (NSUInteger)open->input->replyLength) : @"none within 250 ms"];
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
