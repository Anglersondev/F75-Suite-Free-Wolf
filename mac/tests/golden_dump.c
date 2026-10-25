/* Same output as GoldenDump.cs, from the C core. tests/run-linux.sh diffs the two (LightMode removed: 1.0 has no such field). */
#include "../core/f75_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void P(const char *name, const uint8_t *b) { int i; printf("%s ", name); for (i = 0; i < F75_PACKET; i++) printf("%02X", b[i]); printf("\n"); }
int main(void) {
    uint8_t a[F75_PACKET], c[8][F75_PACKET], m[3][F75_PACKET]; char name[64]; int i, t, colors[F75_SLOTS], br, ms;
    static const int brs[5] = {0, 1, 37, 80, 100};
    f75_macro_event ev[60]; f75_profile p; char *s, err[128];
    for (t = 1; t <= 3; t++) { f75_response_time(a, t); sprintf(name, "response%d", t); P(name, a); }
    for (t = 1; t <= 4; t++) { f75_sleep(a, t); sprintf(name, "sleep%d", t); P(name, a); }
    for (t = 1; t <= 23; t++) { int mo = t <= 20 ? t : t + 1; f75_effect(a, mo, 1 + mo % 5, 1 + (mo * 3) % 5, mo % 4, mo % 9); sprintf(name, "effect%d", mo); P(name, a); }
    for (i = 0; i < F75_SLOTS; i++) colors[i] = (int)((unsigned long long)i * 2654435761ULL % 0xffffff);
    for (br = 0; br < 5; br++) { f75_custom(c, colors, brs[br]); for (i = 0; i < 8; i++) { sprintf(name, "custom%d.%d", brs[br], i); P(name, c[i]); } }
    for (ms = 0; ms <= 31000; ms += ms < 400 ? 10 : ms < 4000 ? 50 : 500) printf("timing%d %d %d\n", ms, f75_event_timing(0, ms), f75_event_timing(1, ms));
    for (i = 0; i < 30; i++) { ev[i].code = 4 + i; ev[i].release = 0; ev[i].delay = i * 37; }
    for (i = 29; i >= 0; i--) { ev[59 - i].code = 4 + i; ev[59 - i].release = 1; ev[59 - i].delay = i * 101; }
    if (f75_macro(m, 77, ev, 60, NULL)) return 1;
    for (i = 0; i < 3; i++) { sprintf(name, "macro.%d", i); P(name, m[i]); }
    s = f75_macro_serialize(ev, 60); printf("macrojson %s\n", s); free(s);
    f75_restore_key(a, 77); P("restore", a);
    for (i = 0; i < F75_KEY_COUNT; i++) printf("key %s %d %d %d,%d,%d,%d\n", f75_keys[i].name, f75_keys[i].index, f75_keys[i].code, f75_keys[i].x, f75_keys[i].y, f75_keys[i].w, f75_keys[i].h);
    f75_profile_default(&p); strcpy(p.name, "A\xc3\xa7\xc3\xa3o \"x\" \\ \t \xe2\x9c\x93"); p.colors[3] = 0xABCDEF; p.brightness = 33; p.effect_palette = 4;
    s = f75_profile_serialize(&p); printf("profile %s\n", s); free(s);
    {
        char json[2048]; int n = sprintf(json, "{\"name\":\"\\u00e7\\ud83d\\ude00 a\",\"NAME\":\"dup \\u0041\",\"colors\":[");
        for (i = 0; i < F75_SLOTS; i++) n += sprintf(json + n, i ? ",1e3" : "1e3");
        sprintf(json + n, "],\"brightness\":5.0,\"sleep\":null}");
        if (f75_profile_parse(json, strlen(json), &p, err, sizeof err)) { printf("parse error %s\n", err); return 1; }
        s = f75_profile_serialize(&p); printf("parsed %s\n", s); free(s);
    }
    return 0;
}
