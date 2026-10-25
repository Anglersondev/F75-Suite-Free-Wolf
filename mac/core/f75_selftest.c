/* Offline checks, the same list as SelfTest.cs of the Windows build plus the LightMode / save-all checks. */
#include "f75_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static void (*out)(const char *);
static void check(int ok, const char *name) {
    char line[160];
    snprintf(line, sizeof line, "%s %s", ok ? "PASS" : "FAIL", name);
    if (!ok) failures++;
    if (out) out(line);
}

static int parse_ok(const char *json, f75_profile *p) {
    char err[128];
    return f75_profile_parse(json, strlen(json), p, err, sizeof err) == 0 && f75_profile_validate(p, NULL) == 0;
}

int f75_self_test(void (*log)(const char *)) {
    uint8_t a[F75_PACKET], b[F75_PACKET], c[8][F75_PACKET], m[3][F75_PACKET], all[10][F75_PACKET];
    int colors[F75_SLOTS], i, j, ok, battery, n;
    f75_profile p, q;
    char *json, big[4096];
    failures = 0; out = log;

    { uint8_t one = 1; f75_response_time(a, 1); f75_packet(b, 13, &one, 1); check(memcmp(a, b, F75_PACKET) == 0, "response tier 1 packet"); }
    check(f75_sleep(a, 4) == 0 && a[6] == 4 && f75_sleep(a, 5) < 0, "sleep protocol range");
    memset(colors, 0, sizeof colors); colors[15] = 0x123456; colors[101] = 0xABCDEF;
    check(f75_custom(c, colors, 100) == 0 && f75_valid_packet(c[0]) && c[0][5] == 7 && c[1][5] == 0x0b && c[7][5] == 0xfb, "custom transaction and report length");
    check(c[2][6 + 45] == 0x12 && c[2][6 + 46] == 0x34 && c[2][6 + 47] == 0x56, "RGB channels and Esc index");
    check(c[7][6 + 33] == 0xAB && c[7][6 + 34] == 0xCD && c[7][6 + 35] == 0xEF, "last fragment right arrow index");
    f75_custom(c, colors, 0); ok = 1; for (i = 2; i < 8; i++) for (j = 6; j < F75_PACKET; j++) if (c[i][j]) ok = 0;
    check(ok, "blackout has zero RGB");
    check(f75_event_timing(0, 10) == 1 && f75_event_timing(1, 10) == 129 && f75_event_timing(0, 1000) == 52, "macro timing encoding");
    { f75_macro_event held[2] = {{4, 0, 0}, {5, 0, 0}}; check(f75_macro(m, 42, held, 2, NULL) < 0, "reject held macro keys"); }
    ok = 1; for (i = 0; i < F75_KEY_COUNT; i++) for (j = 0; j < i; j++) if (f75_keys[i].index == f75_keys[j].index) ok = 0;
    check(ok, "81 unique vendor key positions");

    f75_profile_default(&p); p.colors[15] = 0x123456; p.keep_in_tray = 1; strcpy(p.name, "Perfil \"F75\" \\ \xc3\xa7");
    json = f75_profile_serialize(&p); ok = parse_ok(json, &q); free(json);
    check(ok && q.colors[15] == 0x123456 && q.keep_in_tray && strcmp(q.name, p.name) == 0, "profile round trip");
    q.colors_count = 2; check(f75_profile_validate(&q, NULL) < 0, "reject malformed profile");
    check(parse_ok("{\"Version\":1,\"Name\":\"Old profile\",\"Language\":\"pt-BR\",\"Brightness\":80,\"Response\":1,\"Sleep\":2,\"Colors\":[" "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}", &q)
          && q.effect_mode == 7 && q.effect_brightness == 5 && !q.keep_in_tray && q.light_mode == 0, "legacy profiles retain effect defaults");
    f75_effect(a, 22, 5, 4, 0, 0); f75_effect(b, 23, 5, 4, 0, 0); check(a[6] == 21 && b[6] == 22 && f75_effect(a, 21, 5, 4, 0, 0) < 0, "experimental effect IDs skip undeclared mode 21");
    { uint8_t r[7] = {0xaa, 0x55, 0xcc, 0x33, 0x0e, 0, 3}; check(f75_parse_status(r, 7, &battery) == 0 && battery == 0, "zero battery remains valid");
      r[5] = 101; check(f75_parse_status(r, 7, &battery) == 0 && battery == -1, "invalid battery is unavailable instead of fabricated");
      r[5] = 50; check(f75_parse_status(r, 7, &battery) == 0 && battery == 50, "wireless battery parses");
      check(f75_parse_status(r, 2, &battery) < 0, "reject incomplete status report"); }
    { uint8_t rep[64] = {0xaa, 0x55, 0xcc, 0x33, 0x0e, 0x64, 3}, rid[65] = {0, 0xaa, 0x55, 0xcc, 0x33, 0x0e, 0x64, 3};
      check(f75_status_offset(rep, 64) == 0 && f75_status_offset(rid, 65) == 1 && f75_status_offset(rep, 5) < 0, "status found with and without report ID"); }

    /* JavaScriptSerializer wrote this shape in 1.0; old session.json files must still load. */
    n = snprintf(big, sizeof big, "\xef\xbb\xbf{\"Version\":1,\"Name\":\"Meu F75\",\"Language\":\"en\",\"Colors\":[");
    for (i = 0; i < F75_SLOTS; i++) n += snprintf(big + n, sizeof big - (size_t)n, i ? ",9039054" : "9039054");
    snprintf(big + n, sizeof big - (size_t)n, "],\"Brightness\":80,\"Response\":1,\"Sleep\":2,\"EffectMode\":7,\"EffectBrightness\":5,\"EffectSpeed\":4,\"EffectDirection\":0,\"EffectPalette\":0}");
    check(parse_ok(big, &q) && q.colors[107] == 9039054 && strcmp(q.language, "en") == 0, "1.0 session file (with BOM) loads");
    {
        f75_macro_event ev[4] = {{224, 0, 10}, {6, 0, 20}, {6, 1, 10}, {224, 1, 10}}, back[F75_MAX_MACRO_EVENTS]; int cnt; char err[128];
        json = f75_macro_serialize(ev, 4);
        ok = f75_macro_parse(json, strlen(json), back, F75_MAX_MACRO_EVENTS, &cnt, err, sizeof err) == 0; free(json);
        check(ok && cnt == 4 && back[2].release && back[1].delay == 20 && f75_macro(m, 42, back, cnt, NULL) == 0, "macro JSON round trip");
        json = "[{\"code\":4,\"delay\":10},{\"Code\":4,\"Release\":true,\"Delay\":10}]";
        check(f75_macro_parse(json, strlen(json), back, F75_MAX_MACRO_EVENTS, &cnt, err, sizeof err) == 0 && back[0].code == 4, "macro JSON hand-edited");
    }
    {
        static const char *bad[] = {"[", "{\"Brightness\":1.5}", "[{\"Code\":\"x\"}]", "[] x", "{\"Colors\":[1,]}", "{\"KeepInTray\":1}", "{\"Name\":\"\\q\"}"};
        for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
            f75_macro_event ev[F75_MAX_MACRO_EVENTS]; int cnt; char err[128], label[96];
            int rejected = bad[i][0] == '[' ? f75_macro_parse(bad[i], strlen(bad[i]), ev, F75_MAX_MACRO_EVENTS, &cnt, err, sizeof err) < 0 : f75_profile_parse(bad[i], strlen(bad[i]), &q, err, sizeof err) < 0;
            snprintf(label, sizeof label, "reject malformed JSON %s", bad[i]);
            check(rejected, label);
        }
    }

    /* Close-for-good writes the last lighting mode plus response time and sleep. */
    f75_profile_default(&p); p.response = 2; p.sleep = 4;
    n = f75_save_all(all, &p); check(n == 10 && all[0][5] == 7 && all[0][6] == 23 && all[2][5] == 0xf6 && all[8][5] == 0x0d && all[8][6] == 2 && all[9][5] == 0x0c && all[9][6] == 4, "save all: per-key colors + response + sleep");
    p.light_mode = F75_LIGHT_EFFECT; p.effect_mode = 10; n = f75_save_all(all, &p);
    check(n == 3 && all[0][5] == 7 && all[0][6] == 9 && all[1][5] == 0x0d && all[2][5] == 0x0c, "save all: effect + response + sleep");
    p.light_mode = F75_LIGHT_OFF; n = f75_save_all(all, &p); ok = n == 10; for (i = 2; i < 8; i++) for (j = 6; j < F75_PACKET; j++) if (all[i][j]) ok = 0;
    check(ok, "save all: RGB off sends black");
    p.light_mode = 3; check(f75_profile_validate(&p, NULL) < 0 && f75_save_all(all, &p) < 0, "reject invalid LightMode");
    f75_profile_default(&p); json = f75_profile_serialize(&p);
    check(strstr(json, ",\"EffectPalette\":0,\"LightMode\":0,\"KeepInTray\":false}") != NULL, "LightMode serialized before KeepInTray");
    ok = parse_ok(json, &q); free(json); check(ok && q.light_mode == 0, "default profile round trip");
    check(f75_hid_usage_from_mac_keycode(0x00) == 4 && f75_hid_usage_from_mac_keycode(0x06) == 29 && f75_hid_usage_from_mac_keycode(0x1D) == 39 && f75_hid_usage_from_mac_keycode(0x12) == 30 &&
          f75_hid_usage_from_mac_keycode(0x37) == 227 && f75_hid_usage_from_mac_keycode(0x7E) == 82 && f75_hid_usage_from_mac_keycode(0x52) == 98 && f75_hid_usage_from_mac_keycode(0x3F) == 0, "mac key codes map to HID usages");
    return failures;
}
