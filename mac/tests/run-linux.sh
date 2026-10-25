#!/bin/sh
# Checks the C core anywhere a C compiler exists (no Mac needed): self-test, plus a byte-for-byte diff against the
# Windows 1.0 C# code when mono/mcs and the Windows source are available (WINSRC=path/to/F75-Studio-Fonte-1.0/source).
set -e
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/f75-core-test; mkdir -p "$OUT"
cc -std=c99 -Wall -Wextra -O2 -o "$OUT/selftest" core/*.c tests/run_selftest.c -lm
"$OUT/selftest"
cc -std=c99 -Wall -O2 -o "$OUT/golden" core/*.c tests/golden_dump.c -lm
"$OUT/golden" | sed 's/,"LightMode":0//' > "$OUT/c.txt"
if [ -n "$WINSRC" ] && command -v mcs >/dev/null; then
  mcs -langversion:5 -nologo -out:"$OUT/golden.exe" -r:System.Core.dll "$WINSRC/Device.cs" "$WINSRC/Json.cs" "$WINSRC/Model.cs" "$WINSRC/Layout.cs" tests/GoldenDump.cs
  LC_ALL=C.UTF-8 mono "$OUT/golden.exe" > "$OUT/cs.txt"
  diff "$OUT/cs.txt" "$OUT/c.txt" && echo "C core == Windows C# (fresh run)"
fi
diff tests/golden-windows-1.0.txt "$OUT/c.txt" && echo "C core == Windows C# 1.0 ($(wc -l < tests/golden-windows-1.0.txt) lines of packets/JSON)"
