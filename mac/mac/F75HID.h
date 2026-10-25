// IOKit HID transport for the F75: the macOS counterpart of KeyboardDevice in Device.cs.
#import <Foundation/Foundation.h>
#include "../core/f75_core.h"

@interface F75Status : NSObject
@property (copy) NSString *transport; // USB, 2.4 GHz, Receiver, Bluetooth, Disconnected
@property int battery;                // -1 = unavailable
@property BOOL responding;
@property (strong) NSDate *checkedAt;
@property (copy) NSString *detail;
@property (strong) NSData *raw;
@end

@interface F75HID : NSObject
+ (instancetype)shared;
// Plug/unplug of the F75 or its receiver, debounced, on the main thread. Event driven: no polling.
@property (copy) void (^devicesChanged)(void);
- (void)startWatching; // main thread
- (void)stopWatching;  // main thread
// The calls below block (USB I/O); call them on one serial background queue only.
// YES when the last sendPackets wrote without error but the keyboard never answered the 0E query.
@property (readonly) BOOL lastReplyMissing;
- (BOOL)sendPackets:(const uint8_t (*)[F75_PACKET])packets count:(int)count error:(NSError **)error;
- (NSData *)queryStatus:(NSError **)error; // wired F75, raw reply from AA
- (F75Status *)readStatusSnapshot;
// Everything --diagnose needs to find a transport problem: every 1A2C interface, open result, write result, reply.
- (NSString *)diagnosticReport;
@end
