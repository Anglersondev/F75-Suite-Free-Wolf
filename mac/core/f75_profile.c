/* Profile and macro JSON: a port of Json.cs, with the same acceptance rules, so session/profile files move between Windows and Mac. */
#include "f75_core.h"
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JSON_MAX 131072

enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ };
typedef struct jv {
    int t, b; double n; char *s; size_t slen;
    struct jv *items; char **keys; int count, cap;
} jv;

typedef struct { const char *s; size_t n, i; char *err; size_t errlen; int failed; } parser;

static void jfree(jv *v) {
    int i;
    if (!v) return;
    free(v->s);
    for (i = 0; i < v->count; i++) { jfree(&v->items[i]); if (v->keys) free(v->keys[i]); }
    free(v->items); free(v->keys);
    memset(v, 0, sizeof *v);
}

static int fail(parser *p, const char *msg) {
    if (!p->failed && p->err && p->errlen) {
        if (msg) snprintf(p->err, p->errlen, "%s", msg);
        else snprintf(p->err, p->errlen, "JSON inválido / invalid at %lu", (unsigned long)p->i);
    }
    p->failed = 1;
    return -1;
}

static void skip(parser *p) {
    while (p->i < p->n) {
        unsigned char c = (unsigned char)p->s[p->i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') p->i++;
        /* U+FEFF: Windows writes profiles with a UTF-8 BOM. */
        else if (c == 0xEF && p->i + 2 < p->n && (unsigned char)p->s[p->i + 1] == 0xBB && (unsigned char)p->s[p->i + 2] == 0xBF) p->i += 3;
        else break;
    }
}

typedef struct { char *b; size_t n, cap; } buf;
static int put(buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 64; char *nb;
        while (cap < b->n + n + 1) cap *= 2;
        nb = (char *)realloc(b->b, cap); if (!nb) return -1;
        b->b = nb; b->cap = cap;
    }
    memcpy(b->b + b->n, s, n); b->n += n; b->b[b->n] = 0;
    return 0;
}
static int putc8(buf *b, unsigned cp) {
    char u[4]; size_t n;
    if (cp < 0x80) { u[0] = (char)cp; n = 1; }
    else if (cp < 0x800) { u[0] = (char)(0xC0 | (cp >> 6)); u[1] = (char)(0x80 | (cp & 63)); n = 2; }
    else if (cp < 0x10000) { u[0] = (char)(0xE0 | (cp >> 12)); u[1] = (char)(0x80 | ((cp >> 6) & 63)); u[2] = (char)(0x80 | (cp & 63)); n = 3; }
    else { u[0] = (char)(0xF0 | (cp >> 18)); u[1] = (char)(0x80 | ((cp >> 12) & 63)); u[2] = (char)(0x80 | ((cp >> 6) & 63)); u[3] = (char)(0x80 | (cp & 63)); n = 4; }
    return put(b, u, n);
}

static int hex4(parser *p, unsigned *out) {
    unsigned v = 0; int k;
    if (p->i + 4 > p->n) return -1;
    for (k = 0; k < 4; k++) {
        char c = p->s[p->i + k]; v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return -1;
    }
    p->i += 4; *out = v;
    return 0;
}

static int str(parser *p, char **out, size_t *outlen) {
    buf b = {0, 0, 0};
    p->i++;
    if (put(&b, "", 0)) return fail(p, "out of memory");
    while (p->i < p->n) {
        char c = p->s[p->i++];
        if (c == '"') { *out = b.b; *outlen = b.n; return 0; }
        if (c != '\\') { if (put(&b, &c, 1)) break; continue; }
        if (p->i >= p->n) break;
        c = p->s[p->i++];
        switch (c) {
        case '"': case '\\': case '/': put(&b, &c, 1); break;
        case 'b': putc8(&b, '\b'); break;
        case 'f': putc8(&b, '\f'); break;
        case 'n': putc8(&b, '\n'); break;
        case 'r': putc8(&b, '\r'); break;
        case 't': putc8(&b, '\t'); break;
        case 'u': {
            unsigned u, lo;
            if (hex4(p, &u)) { free(b.b); return fail(p, NULL); }
            if (u >= 0xD800 && u <= 0xDBFF && p->i + 6 <= p->n && p->s[p->i] == '\\' && p->s[p->i + 1] == 'u') {
                size_t save = p->i; p->i += 2;
                if (!hex4(p, &lo) && lo >= 0xDC00 && lo <= 0xDFFF) u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                else p->i = save;
            }
            if (u >= 0xD800 && u <= 0xDFFF) u = 0xFFFD;
            putc8(&b, u);
            break;
        }
        default: free(b.b); return fail(p, NULL);
        }
    }
    free(b.b);
    return fail(p, NULL);
}

static int word(parser *p, const char *w) {
    size_t n = strlen(w);
    if (p->i + n > p->n || memcmp(p->s + p->i, w, n) != 0) return 0;
    p->i += n;
    return 1;
}

static int add(jv *v, jv *item, char *key) {
    if (v->count == v->cap) {
        int cap = v->cap ? v->cap * 2 : 8;
        jv *items = (jv *)realloc(v->items, sizeof(jv) * (size_t)cap);
        if (!items) return -1;
        v->items = items;
        if (v->t == J_OBJ) { char **keys = (char **)realloc(v->keys, sizeof(char *) * (size_t)cap); if (!keys) return -1; v->keys = keys; }
        v->cap = cap;
    }
    v->items[v->count] = *item;
    if (v->t == J_OBJ) v->keys[v->count] = key;
    v->count++;
    return 0;
}

static int value(parser *p, jv *v, int depth) {
    char c;
    memset(v, 0, sizeof *v);
    if (depth > 16) return fail(p, NULL);
    skip(p);
    if (p->i >= p->n) return fail(p, NULL);
    c = p->s[p->i];
    if (c == '{' || c == '[') {
        int obj = c == '{';
        char close = obj ? '}' : ']';
        v->t = obj ? J_OBJ : J_ARR;
        p->i++; skip(p);
        if (p->i < p->n && p->s[p->i] == close) { p->i++; return 0; }
        for (;;) {
            jv item; char *key = NULL; size_t klen;
            if (obj) {
                skip(p);
                if (p->i >= p->n || p->s[p->i] != '"') return fail(p, NULL);
                if (str(p, &key, &klen)) return -1;
                skip(p);
                if (p->i >= p->n || p->s[p->i] != ':') { free(key); return fail(p, NULL); }
                p->i++;
            }
            if (value(p, &item, depth + 1)) { free(key); jfree(&item); return -1; }
            if (add(v, &item, key)) { free(key); jfree(&item); return fail(p, "out of memory"); }
            skip(p);
            if (p->i < p->n && p->s[p->i] == ',') { p->i++; continue; }
            if (p->i < p->n && p->s[p->i] == close) { p->i++; return 0; }
            return fail(p, NULL);
        }
    }
    if (c == '"') { v->t = J_STR; return str(p, &v->s, &v->slen); }
    if (word(p, "true")) { v->t = J_BOOL; v->b = 1; return 0; }
    if (word(p, "false")) { v->t = J_BOOL; return 0; }
    if (word(p, "null")) { v->t = J_NULL; return 0; }
    {
        size_t start = p->i, len; char tmp[64], *end; const char *dp = localeconv()->decimal_point;
        while (p->i < p->n && ((p->s[p->i] >= '0' && p->s[p->i] <= '9') || strchr("-+.eE", p->s[p->i]) != NULL)) p->i++;
        len = p->i - start;
        if (len == 0 || len >= sizeof tmp) { p->i = start; return fail(p, NULL); }
        memcpy(tmp, p->s + start, len); tmp[len] = 0;
        /* strtod follows the C locale's decimal point; JSON always uses '.'. */
        if (dp && dp[0] && dp[0] != '.') { char *dot = strchr(tmp, '.'); if (dot) *dot = dp[0]; }
        v->n = strtod(tmp, &end);
        if (end != tmp + len || isinf(v->n) || isnan(v->n)) { p->i = start; return fail(p, NULL); }
        v->t = J_NUM;
        return 0;
    }
}

static int parse(const char *json, size_t length, jv *root, char *err, size_t errlen) {
    parser p;
    memset(&p, 0, sizeof p);
    p.s = json; p.n = length; p.err = err; p.errlen = errlen;
    memset(root, 0, sizeof *root);
    if (!json || length > JSON_MAX) return fail(&p, "JSON too large");
    if (value(&p, root, 0)) { jfree(root); return -1; }
    skip(&p);
    if (p.i != p.n) { jfree(root); return fail(&p, "JSON: trailing data"); }
    return 0;
}

static int ieq(const char *a, const char *b) {
    for (; *a && *b; a++, b++) {
        char x = *a, y = *b;
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return 0;
    }
    return *a == *b;
}

/* Keys are case-insensitive and the last duplicate wins, like the Dictionary in Json.cs. */
static jv *get(jv *o, const char *key) {
    int i;
    for (i = o->count - 1; i >= 0; i--) if (ieq(o->keys[i], key)) return &o->items[i];
    return NULL;
}

static int seterr(char *err, size_t errlen, const char *a, const char *b) {
    if (err && errlen) snprintf(err, errlen, "%s%s%s", a, b ? b : "", b ? " must be an integer" : "");
    return -1;
}

static int to_int(jv *v, int *out) {
    if (v->n != floor(v->n) || v->n < -2147483648.0 || v->n > 2147483647.0) return -1;
    *out = (int)v->n;
    return 0;
}

static int geti(jv *o, const char *key, int *out, char *err, size_t errlen) {
    jv *v = get(o, key);
    if (!v || v->t == J_NULL) return 0;
    if (v->t != J_NUM) { if (err && errlen) snprintf(err, errlen, "JSON: %s must be a number", key); return -1; }
    if (to_int(v, out)) return seterr(err, errlen, "JSON: ", key);
    return 0;
}

/* Strings that do not fit the struct can never pass Validate, so they are stored empty (invalid). */
static void gets_(jv *o, const char *key, char *out, size_t cap) {
    jv *v = get(o, key);
    if (!v) return;
    if (v->t != J_STR || v->slen >= cap || memchr(v->s, 0, v->slen)) { out[0] = 0; return; }
    memcpy(out, v->s, v->slen + 1);
}

void f75_profile_default(f75_profile *p) {
    int i;
    memset(p, 0, sizeof *p);
    p->version = 1; strcpy(p->name, "Meu F75"); strcpy(p->language, "pt-BR");
    p->colors_count = F75_SLOTS;
    for (i = 0; i < F75_KEY_COUNT; i++) p->colors[f75_keys[i].index] = 0x89F0CE;
    p->brightness = 80; p->response = 1; p->sleep = 2;
    p->effect_mode = 7; p->effect_brightness = 5; p->effect_speed = 4;
}

int f75_profile_parse(const char *json, size_t length, f75_profile *p, char *err, size_t errlen) {
    jv root, *v; int rc = -1;
    if (parse(json, length, &root, err, errlen)) return -1;
    if (root.t != J_OBJ) { seterr(err, errlen, "JSON: object expected", NULL); goto done; }
    /* Missing colors stay black, as in a fresh Profile() on Windows. */
    f75_profile_default(p);
    memset(p->colors, 0, sizeof p->colors);
    if (geti(&root, "Version", &p->version, err, errlen)) goto done;
    gets_(&root, "Name", p->name, sizeof p->name);
    gets_(&root, "Language", p->language, sizeof p->language);
    if ((v = get(&root, "Colors")) != NULL) {
        int i;
        if (v->t != J_ARR) { seterr(err, errlen, "JSON: Colors", NULL); goto done; }
        p->colors_count = v->count;
        for (i = 0; i < v->count; i++) {
            int c;
            if (v->items[i].t != J_NUM || to_int(&v->items[i], &c)) { seterr(err, errlen, "JSON: Colors", NULL); goto done; }
            if (i < F75_SLOTS) p->colors[i] = c;
        }
    }
    if (geti(&root, "Brightness", &p->brightness, err, errlen) || geti(&root, "Response", &p->response, err, errlen) || geti(&root, "Sleep", &p->sleep, err, errlen)) goto done;
    if (geti(&root, "EffectMode", &p->effect_mode, err, errlen) || geti(&root, "EffectBrightness", &p->effect_brightness, err, errlen) || geti(&root, "EffectSpeed", &p->effect_speed, err, errlen)) goto done;
    if (geti(&root, "EffectDirection", &p->effect_direction, err, errlen) || geti(&root, "EffectPalette", &p->effect_palette, err, errlen)) goto done;
    if (geti(&root, "LightMode", &p->light_mode, err, errlen)) goto done;
    if ((v = get(&root, "KeepInTray")) != NULL) {
        if (v->t != J_BOOL) { seterr(err, errlen, "JSON: KeepInTray", NULL); goto done; }
        p->keep_in_tray = v->b;
    }
    rc = 0;
done:
    jfree(&root);
    return rc;
}

/* UTF-16 length and char.IsWhiteSpace, so Name follows the same limits as String.Length / IsNullOrWhiteSpace in C#. */
static int name_ok(const char *s) {
    const unsigned char *u = (const unsigned char *)s;
    int units = 0, visible = 0;
    while (*u) {
        unsigned cp; int n;
        if (*u < 0x80) { cp = *u; n = 1; }
        else if ((*u & 0xE0) == 0xC0) { cp = *u & 31; n = 2; }
        else if ((*u & 0xF0) == 0xE0) { cp = *u & 15; n = 3; }
        else if ((*u & 0xF8) == 0xF0) { cp = *u & 7; n = 4; }
        else return 0;
        { int k; for (k = 1; k < n; k++) { if ((u[k] & 0xC0) != 0x80) return 0; cp = (cp << 6) | (u[k] & 63); } }
        units += cp >= 0x10000 ? 2 : 1;
        if (!((cp >= 9 && cp <= 13) || cp == ' ' || cp == 0x85 || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000)) visible = 1;
        u += n;
    }
    return visible && units <= 80;
}

int f75_profile_validate(const f75_profile *p, const char **err) {
    int i;
    if (!((p->effect_mode >= 1 && p->effect_mode <= 20) || p->effect_mode == 22 || p->effect_mode == 23) || p->effect_brightness < 1 || p->effect_brightness > 5 || p->effect_speed < 1 || p->effect_speed > 5 ||
        p->effect_direction < 0 || p->effect_direction > 3 || p->effect_palette < 0 || p->effect_palette > 8) { if (err) *err = "Efeito inválido / Invalid effect"; return -1; }
    if (p->version != 1 || p->colors_count != F75_SLOTS || p->brightness < 0 || p->brightness > 100 || p->response < 1 || p->response > 3 || p->sleep < 1 || p->sleep > 4 ||
        p->light_mode < 0 || p->light_mode > 2 || (strcmp(p->language, "pt-BR") != 0 && strcmp(p->language, "en") != 0) || !name_ok(p->name)) goto bad;
    for (i = 0; i < F75_SLOTS; i++) if (p->colors[i] < 0 || p->colors[i] > 0xffffff) goto bad;
    return 0;
bad:
    if (err) *err = "Perfil inválido / Invalid profile";
    return -1;
}

static void quote(buf *b, const char *s) {
    put(b, "\"", 1);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { char e[2] = {'\\', (char)c}; put(b, e, 2); }
        else if (c < ' ') { char e[8]; snprintf(e, sizeof e, "\\u%04x", c); put(b, e, 6); }
        else put(b, (const char *)&c, 1);
    }
    put(b, "\"", 1);
}

static void num(buf *b, const char *prefix, int v) { char t[48]; int n = snprintf(t, sizeof t, "%s%d", prefix, v); put(b, t, (size_t)n); }

char *f75_profile_serialize(const f75_profile *p) {
    buf b = {0, 0, 0}; int i;
    num(&b, "{\"Version\":", p->version);
    put(&b, ",\"Name\":", 8); quote(&b, p->name);
    put(&b, ",\"Language\":", 12); quote(&b, p->language);
    put(&b, ",\"Colors\":[", 11);
    for (i = 0; i < p->colors_count && i < F75_SLOTS; i++) num(&b, i ? "," : "", p->colors[i]);
    num(&b, "],\"Brightness\":", p->brightness); num(&b, ",\"Response\":", p->response); num(&b, ",\"Sleep\":", p->sleep);
    num(&b, ",\"EffectMode\":", p->effect_mode); num(&b, ",\"EffectBrightness\":", p->effect_brightness); num(&b, ",\"EffectSpeed\":", p->effect_speed);
    num(&b, ",\"EffectDirection\":", p->effect_direction); num(&b, ",\"EffectPalette\":", p->effect_palette);
    num(&b, ",\"LightMode\":", p->light_mode);
    put(&b, ",\"KeepInTray\":", 14); put(&b, p->keep_in_tray ? "true}" : "false}", p->keep_in_tray ? 5 : 6);
    return b.b;
}

int f75_macro_parse(const char *json, size_t length, f75_macro_event *out, int capacity, int *count, char *err, size_t errlen) {
    jv root; int i, rc = -1;
    *count = 0;
    if (parse(json, length, &root, err, errlen)) return -1;
    if (root.t != J_ARR) { seterr(err, errlen, "JSON: array expected", NULL); goto done; }
    if (root.count > capacity) { seterr(err, errlen, "Macro length / tamanho: 2–60", NULL); goto done; }
    for (i = 0; i < root.count; i++) {
        jv *o = &root.items[i], *r;
        f75_macro_event e = {0, 0, 0};
        if (o->t != J_OBJ) { seterr(err, errlen, "JSON: object expected", NULL); goto done; }
        if ((r = get(o, "Release")) != NULL && r->t != J_NULL) {
            if (r->t != J_BOOL) { seterr(err, errlen, "JSON: Release", NULL); goto done; }
            e.release = r->b;
        }
        if (geti(o, "Code", &e.code, err, errlen) || geti(o, "Delay", &e.delay, err, errlen)) goto done;
        out[i] = e;
    }
    *count = root.count;
    rc = 0;
done:
    jfree(&root);
    return rc;
}

char *f75_macro_serialize(const f75_macro_event *events, int count) {
    buf b = {0, 0, 0}; int i;
    put(&b, "[", 1);
    for (i = 0; i < count; i++) {
        num(&b, i ? ",{\"Code\":" : "{\"Code\":", events[i].code);
        put(&b, events[i].release ? ",\"Release\":true" : ",\"Release\":false", events[i].release ? 15 : 16);
        num(&b, ",\"Delay\":", events[i].delay);
        put(&b, "}", 1);
    }
    put(&b, "]", 1);
    return b.b;
}

int f75_save_all(uint8_t out[10][F75_PACKET], const f75_profile *p) {
    int n;
    if (f75_profile_validate(p, NULL)) return -1;
    if (p->light_mode == F75_LIGHT_EFFECT) {
        if (f75_effect(out[0], p->effect_mode, p->effect_brightness, p->effect_speed, p->effect_direction, p->effect_palette)) return -1;
        n = 1;
    } else {
        if (f75_custom((uint8_t (*)[F75_PACKET])out, p->colors, p->light_mode == F75_LIGHT_OFF ? 0 : p->brightness)) return -1;
        n = 8;
    }
    if (f75_response_time(out[n], p->response) || f75_sleep(out[n + 1], p->sleep)) return -1;
    return n + 2;
}
