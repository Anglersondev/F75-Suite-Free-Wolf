#include "../core/f75_core.h"
#include <stdio.h>
static void line(const char *s) { puts(s); }
int main(void) { int f = f75_self_test(line); printf("%d failure(s)\n", f); return f != 0; }
