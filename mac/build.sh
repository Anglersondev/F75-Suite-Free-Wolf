#!/bin/sh
# Builds "F75 Studio.app" (Apple Silicon + Intel) and F75-Studio-1.0.dmg on a Mac.
# Needs only the Command Line Tools (xcode-select --install); Xcode is not required.
set -e
cd "$(dirname "$0")"
if ! xcrun --find clang >/dev/null 2>&1; then
  echo "Instale as ferramentas de linha de comando: xcode-select --install"; exit 1
fi
OUT=build; APP="$OUT/F75 Studio.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "1/4 Testes do núcleo (protocolo e perfil)"
clang -std=c99 -Wall -Wextra -O2 -o "$OUT/core-selftest" core/*.c tests/run_selftest.c
"$OUT/core-selftest" | tail -1
clang -std=c99 -O2 -o "$OUT/golden" core/*.c tests/golden_dump.c
"$OUT/golden" | sed 's/,"LightMode":0//' | diff -q tests/golden-windows-1.0.txt - >/dev/null && echo "Pacotes idênticos aos do Windows 1.0" || { echo "ERRO: pacotes diferentes do Windows 1.0"; exit 1; }

echo "2/4 Compilando (arm64 + x86_64, macOS 11+)"
ARCHS=${ARCHS:-"-arch arm64 -arch x86_64"}
clang $ARCHS -mmacosx-version-min=11.0 -O2 -Wall -fobjc-arc \
  core/f75_core.c core/f75_profile.c core/f75_selftest.c mac/F75HID.m mac/F75Views.m mac/F75App.m \
  -framework Cocoa -framework IOKit -o "$APP/Contents/MacOS/F75Studio"
strip -x "$APP/Contents/MacOS/F75Studio"
cp Info.plist "$APP/Contents/Info.plist"
cp F75.icns "$APP/Contents/Resources/F75.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "3/4 Assinatura local (ad-hoc)"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/F75Studio" --self-test | tail -1

echo "4/4 Imagem de disco"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "F75 Studio" -srcfolder "$STAGE" -ov -format UDZO "$OUT/F75-Studio-1.0.dmg"
rm -rf "$STAGE"
lipo -info "$APP/Contents/MacOS/F75Studio"
du -sh "$APP" "$OUT/F75-Studio-1.0.dmg"
echo "Pronto: $OUT/F75-Studio-1.0.dmg"
