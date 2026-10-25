/* F75 Studio core: FREE WOLF F75 (USB 1A2C:A073, HID FF02:0002) protocol, layout and profile format.
   Plain C99 with no platform headers, so the same file builds on macOS, Linux and Windows.
   Byte-for-byte equivalent to Device.cs / Json.cs / Layout.cs of the Windows 1.0 final; tests/ checks that. */
#ifndef F75_CORE_H
#define F75_CORE_H
#include <stddef.h>
#include <stdint.h>

#define F75_VID 0x1A2C
#define F75_PID 0xA073
#define F75_RECEIVER_PID 0x8FFF
#define F75_USAGE_PAGE 0xFF02
#define F75_USAGE 0x0002
/* Packets are kept in the Windows form: byte 0 = report ID 0, then AA 55 CC 33 command payload, 65 bytes.
   macOS sends bytes 1..64 with report ID 0. */
#define F75_PACKET 65
#define F75_SLOTS 108
#define F75_KEY_COUNT 81
#define F75_MAX_MACRO_EVENTS 60
#define F75_NAME_MAX 256
#define F75_LIGHT_CUSTOM 0
#define F75_LIGHT_EFFECT 1
#define F75_LIGHT_OFF 2

typedef struct { const char *name; int index, code, x, y, w, h; } f75_key;
extern const f75_key f75_keys[F75_KEY_COUNT];

typedef struct { int code, release, delay; } f75_macro_event;

typedef struct {
    int version; char name[F75_NAME_MAX]; char language[8];
    int colors[F75_SLOTS]; int colors_count;
    int brightness, response, sleep;
    int light_mode; /* F75_LIGHT_*: what closing the app writes back to the keyboard */
    int keep_in_tray; /* 1 = stay in background (menu bar / tray), 0 = close for good after saving to the keyboard */
    int effect_mode, effect_brightness, effect_speed, effect_direction, effect_palette;
} f75_profile;

/* All builders return 0 on success and -1 on invalid input (out is then undefined). */
int f75_packet(uint8_t out[F75_PACKET], int command, const uint8_t *payload, int length);
int f75_response_time(uint8_t out[F75_PACKET], int tier);
int f75_sleep(uint8_t out[F75_PACKET], int tier);
int f75_effect(uint8_t out[F75_PACKET], int mode, int brightness, int speed, int direction, int palette);
/* Mode 24 + 0B + six RGB blocks: always 8 packets. */
int f75_custom(uint8_t out[8][F75_PACKET], const int colors[F75_SLOTS], int brightness);
int f75_restore_key(uint8_t out[F75_PACKET], int index);
/* Everything the firmware keeps: lighting per p->light_mode, then response time and sleep. Returns packet count (3 or 10), -1 if invalid. */
int f75_save_all(uint8_t out[10][F75_PACKET], const f75_profile *p);
int f75_event_timing(int release, int ms); /* encoded byte, or -1 */
/* Always 3 packets. err (optional) receives a static bilingual message. */
int f75_macro(uint8_t out[3][F75_PACKET], int trigger, const f75_macro_event *events, int count, const char **err);
int f75_valid_packet(const uint8_t packet[F75_PACKET]);
/* raw starts at AA (report ID removed). Returns 0 and battery 0..100, or -1 when unavailable; -1 if malformed. */
int f75_parse_status(const uint8_t *raw, int length, int *battery);
/* Finds AA 55 CC 33 0E in an input report, with or without a leading report ID. Returns offset or -1. */
int f75_status_offset(const uint8_t *report, int length);

/* macOS virtual key code (kVK_*) to USB HID usage, 0 when unmapped. Same table as HidUsage() in App.cs. */
int f75_hid_usage_from_mac_keycode(int keycode);

void f75_profile_default(f75_profile *p);
int f75_profile_validate(const f75_profile *p, const char **err);
/* Same acceptance rules as Json.ParseProfile; profiles move between Windows and Mac unchanged. */
int f75_profile_parse(const char *json, size_t length, f75_profile *out, char *err, size_t errlen);
char *f75_profile_serialize(const f75_profile *p); /* malloc'd, caller frees */
int f75_macro_parse(const char *json, size_t length, f75_macro_event *out, int capacity, int *count, char *err, size_t errlen);
char *f75_macro_serialize(const f75_macro_event *events, int count);

/* Offline checks mirroring SelfTest.cs; prints PASS/FAIL lines through log (may be NULL). Returns failures. */
int f75_self_test(void (*log)(const char *line));
#endif
