/* Protocol, layout and key map. See PROTOCOLO.md of the Windows source for the evidence behind each command. */
#include "f75_core.h"
#include <string.h>

/* Generated from Layout.cs (vendor layouts\kb-k600t.xml 1.0.4.4): name, matrix index, HID usage, x, y, width, height. */
const f75_key f75_keys[F75_KEY_COUNT] = {
    {"Esc",15,41,21,26,32,32},
    {"F1",14,58,63,26,32,32},
    {"F2",13,59,97,26,32,32},
    {"F3",12,60,130,26,32,32},
    {"F4",11,61,164,26,32,32},
    {"F5",10,62,206,26,32,32},
    {"F6",9,63,240,26,32,32},
    {"F7",8,64,274,26,32,32},
    {"F8",7,65,308,26,32,32},
    {"F9",6,66,350,26,32,32},
    {"F10",5,67,384,26,32,32},
    {"F11",4,68,417,26,32,32},
    {"F12",3,69,451,26,32,32},
    {"Del",43,76,494,26,32,32},
    {"`~",16,53,21,68,32,32},
    {"1!",17,30,54,68,32,32},
    {"2@",18,31,88,68,32,32},
    {"3#",19,32,121,68,32,32},
    {"4$",20,33,155,68,32,32},
    {"5%",21,34,189,68,32,32},
    {"6^",22,35,223,68,32,32},
    {"7&",23,36,257,68,32,32},
    {"8*",24,37,291,68,32,32},
    {"9(",25,38,325,68,32,32},
    {"0)",26,39,358,68,32,32},
    {"-_",27,45,392,68,32,32},
    {"=+",28,46,426,68,32,32},
    {"Backspace",29,42,460,68,65,32},
    {"Home",31,74,542,68,32,32},
    {"Tab",57,43,21,102,50,32},
    {"Q",56,20,71,102,32,32},
    {"W",55,26,105,102,32,32},
    {"E",54,8,139,102,32,32},
    {"R",53,21,172,102,32,32},
    {"T",52,23,206,102,32,32},
    {"Y",51,28,240,102,32,32},
    {"U",50,24,274,102,32,32},
    {"I",49,12,308,102,32,32},
    {"O",48,18,342,102,32,32},
    {"P",47,19,376,102,32,32},
    {"[{",46,47,409,102,32,32},
    {"]}",45,48,443,102,32,32},
    {"\\|",44,49,477,102,50,32},
    {"PgUp",32,75,543,102,32,32},
    {"CapsLock",58,57,20,135,60,32},
    {"A",59,4,79,135,32,32},
    {"S",60,22,113,135,32,32},
    {"D",61,7,147,135,32,32},
    {"F",62,9,181,135,32,32},
    {"G",63,10,215,135,32,32},
    {"H",64,11,249,135,32,32},
    {"J",65,13,283,135,32,32},
    {"K",66,14,316,135,32,32},
    {"L",67,15,350,135,32,32},
    {";:",68,51,385,135,32,32},
    {"'\"",69,52,418,135,32,32},
    {"Enter",70,40,453,135,75,32},
    {"PgDn",41,78,543,135,32,32},
    {"Shift",90,225,20,169,74,34},
    {"Z",89,29,96,169,34,34},
    {"X",88,27,130,169,34,34},
    {"C",87,6,164,169,34,34},
    {"V",86,25,198,169,34,34},
    {"B",85,5,232,169,34,34},
    {"N",84,17,265,169,34,34},
    {"M",83,16,299,169,34,34},
    {",<",82,54,333,169,34,34},
    {".>",81,55,367,169,34,34},
    {"/?",80,56,401,169,34,34},
    {"Shift",79,229,435,169,57,34},
    {"↑",78,82,501,176,34,34},
    {"End",42,77,543,169,31,31},
    {"Ctrl",91,224,21,203,40,34},
    {"Win",92,227,63,203,40,34},
    {"Alt",93,226,105,203,40,34},
    {"Space",94,44,147,203,210,34},
    {"Fn",97,175,359,203,40,34},
    {"Ctrl",98,228,401,203,40,34},
    {"←",99,80,467,210,34,34},
    {"↓",100,81,501,210,34,34},
    {"→",101,79,535,210,34,34},
};

static const uint8_t header[4] = {0xaa, 0x55, 0xcc, 0x33};

int f75_packet(uint8_t out[F75_PACKET], int command, const uint8_t *payload, int length) {
    if (length < 0 || length > 59 || command < 0 || command > 255) return -1;
    memset(out, 0, F75_PACKET);
    memcpy(out + 1, header, 4);
    out[5] = (uint8_t)command;
    if (length > 0) memcpy(out + 6, payload, (size_t)length);
    return 0;
}

int f75_response_time(uint8_t out[F75_PACKET], int tier) {
    uint8_t b = (uint8_t)tier;
    if (tier < 1 || tier > 3) return -1;
    return f75_packet(out, 0x0d, &b, 1);
}

int f75_sleep(uint8_t out[F75_PACKET], int tier) {
    uint8_t b = (uint8_t)tier;
    if (tier < 1 || tier > 4) return -1;
    return f75_packet(out, 0x0c, &b, 1);
}

int f75_effect(uint8_t out[F75_PACKET], int mode, int brightness, int speed, int direction, int palette) {
    uint8_t p[5];
    if ((mode < 1 || mode > 20) && mode != 22 && mode != 23 && mode != 24) return -1;
    if (brightness < 1 || brightness > 5 || speed < 1 || speed > 5 || direction < 0 || direction > 3 || palette < 0 || palette > 8) return -1;
    p[0] = (uint8_t)(mode - 1); p[1] = (uint8_t)(brightness - 1); p[2] = (uint8_t)(speed - 1); p[3] = (uint8_t)direction; p[4] = (uint8_t)palette;
    return f75_packet(out, 7, p, 5);
}

int f75_custom(uint8_t out[8][F75_PACKET], const int colors[F75_SLOTS], int brightness) {
    uint8_t rgb[F75_SLOTS * 3];
    int i;
    if (brightness < 0 || brightness > 100) return -1;
    for (i = 0; i < F75_SLOTS; i++) {
        rgb[i * 3] = (uint8_t)(((colors[i] >> 16) & 255) * brightness / 100);
        rgb[i * 3 + 1] = (uint8_t)(((colors[i] >> 8) & 255) * brightness / 100);
        rgb[i * 3 + 2] = (uint8_t)((colors[i] & 255) * brightness / 100);
    }
    /* Custom mode is sent at firmware brightness 5; the app scales the channels itself. */
    if (f75_effect(out[0], 24, 5, 4, 0, 0) || f75_packet(out[1], 0x0b, NULL, 0)) return -1;
    for (i = 0; i < 6; i++) if (f75_packet(out[2 + i], 0xf6 + i, rgb + i * 54, 54)) return -1;
    return 0;
}

int f75_restore_key(uint8_t out[F75_PACKET], int index) {
    uint8_t p[3];
    if (index < 0 || index >= F75_SLOTS) return -1;
    p[0] = 1; p[1] = (uint8_t)index; p[2] = 0;
    return f75_packet(out, 4, p, 3);
}

/* 0x4232F0 in vendor 1.0.4.4: bit 7 release; bits 5..6 scale; low 5 bits delay. */
int f75_event_timing(int release, int ms) {
    int unit, scale, units;
    if (ms < 0 || ms > 31000) return -1;
    unit = ms <= 310 ? 10 : ms <= 1550 ? 50 : ms <= 3100 ? 100 : 1000;
    scale = unit == 10 ? 0 : unit == 50 ? 1 : unit == 100 ? 2 : 3;
    units = ms / unit; if (units < 1) units = 1;
    return (release ? 128 : 0) | (scale << 5) | units;
}

int f75_macro(uint8_t out[3][F75_PACKET], int trigger, const f75_macro_event *events, int count, const char **err) {
    uint8_t held[256], data[162];
    int i, open = 0;
    const char *e = NULL;
    if (trigger < 0 || trigger > 107 || count < 2 || count > F75_MAX_MACRO_EVENTS) { e = "Macro length / tamanho: 2–60"; goto fail; }
    memset(held, 0, sizeof held);
    for (i = 0; i < count; i++) {
        int c = events[i].code;
        if (c < 4 || c > 231) { e = "Invalid key"; goto fail; }
        if (events[i].release) { if (!held[c]) { e = "Key-up without key-down"; goto fail; } held[c] = 0; open--; }
        else { if (held[c]) { e = "Repeated key-down"; goto fail; } held[c] = 1; open++; }
    }
    if (open != 0) { e = "Macro leaves keys pressed"; goto fail; }
    memset(data, 0, sizeof data);
    data[0] = 1; data[1] = (uint8_t)trigger; data[2] = 1; data[3] = (uint8_t)count;
    for (i = 0; i < count; i++) {
        int t = f75_event_timing(events[i].release, events[i].delay);
        if (t < 0) { e = "Delay: 0–31000 ms"; goto fail; }
        data[4 + i * 2] = (uint8_t)events[i].code;
        data[5 + i * 2] = (uint8_t)t;
    }
    for (i = 0; i < 3; i++) f75_packet(out[i], i, data + i * 54, 54);
    return 0;
fail:
    if (err) *err = e;
    return -1;
}

int f75_valid_packet(const uint8_t packet[F75_PACKET]) {
    return packet != NULL && packet[0] == 0 && memcmp(packet + 1, header, 4) == 0;
}

int f75_parse_status(const uint8_t *raw, int length, int *battery) {
    if (raw == NULL || length < 7 || memcmp(raw, header, 4) != 0 || raw[4] != 0x0e) return -1;
    /* Byte 6 is not a confirmed transport flag; only the battery byte is used. */
    if (battery) *battery = raw[5] <= 100 ? raw[5] : -1;
    return 0;
}

int f75_status_offset(const uint8_t *report, int length) {
    int offset = length > 0 && report[0] == 0 ? 1 : 0;
    if (length >= offset + 7 && memcmp(report + offset, header, 4) == 0 && report[offset + 4] == 0x0e) return offset;
    return -1;
}

int f75_hid_usage_from_mac_keycode(int k) {
    /* kVK_ANSI_* letters are not in alphabetical order on macOS. */
    static const signed char letters[26] = {0x00,0x0B,0x08,0x02,0x0E,0x03,0x05,0x04,0x22,0x26,0x28,0x25,0x2E,0x2D,0x1F,0x23,0x0C,0x0F,0x01,0x11,0x20,0x09,0x0D,0x07,0x10,0x06};
    static const signed char digits[10] = {0x1D,0x12,0x13,0x14,0x15,0x17,0x16,0x1A,0x1C,0x19}; /* 0..9 */
    static const signed char keypad[10] = {0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5B,0x5C};
    static const short pairs[][2] = {
        {0x24,40},{0x35,41},{0x33,42},{0x30,43},{0x31,44},{0x1B,45},{0x18,46},{0x21,47},{0x1E,48},{0x2A,49},{0x29,51},{0x27,52},{0x32,53},
        {0x2B,54},{0x2F,55},{0x2C,56},{0x39,57},
        {0x7A,58},{0x78,59},{0x63,60},{0x76,61},{0x60,62},{0x61,63},{0x62,64},{0x64,65},{0x65,66},{0x6D,67},{0x67,68},{0x6F,69},
        {0x69,70},{0x6B,71},{0x71,72}, /* F13/F14/F15 = Print Screen / Scroll Lock / Pause on PC keyboards */
        {0x72,73},{0x73,74},{0x74,75},{0x75,76},{0x77,77},{0x79,78},{0x7C,79},{0x7B,80},{0x7D,81},{0x7E,82},
        {0x47,83},{0x4B,84},{0x43,85},{0x4E,86},{0x45,87},{0x4C,88},{0x41,99},{0x0A,100},{0x6E,101},{0x5E,135},
        {0x3B,224},{0x38,225},{0x3A,226},{0x37,227},{0x3E,228},{0x3C,229},{0x3D,230},{0x36,231}
    };
    int i;
    for (i = 0; i < 26; i++) if (letters[i] == k) return 4 + i;
    for (i = 1; i < 10; i++) if (digits[i] == k) return 29 + i;
    if (k == digits[0]) return 39;
    for (i = 1; i < 10; i++) if (keypad[i] == k) return 88 + i;
    if (k == keypad[0]) return 98;
    for (i = 0; i < (int)(sizeof pairs / sizeof pairs[0]); i++) if (pairs[i][0] == k) return pairs[i][1];
    return 0;
}
