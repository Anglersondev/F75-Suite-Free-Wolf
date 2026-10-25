# F75 Suite · Free Wolf

**A lightweight, open-source companion app for the FREE WOLF F75 keyboard, for Windows and macOS.**

Paint every key, pick lighting effects, tune response time and sleep, record macros, and then get out of the way. F75 Studio is written to use as little RAM and CPU as possible: by default it writes your settings to the keyboard and **quits completely**, so nothing stays running in the background.

> **Unofficial project.** F75 Suite is an independent, community-made tool. It is not affiliated with, endorsed by, or supported by FREE WOLF or the keyboard's manufacturer. "FREE WOLF" and "F75" are used only to say which keyboard this software works with. No code, images, or files from the original vendor software are included in this repository.

---

## Why

The vendor driver for the F75 is a resident Windows app. This project replaces it with something smaller and native on each system:

- **Native UI on each OS.** WPF on Windows, plain AppKit (Objective-C) on macOS. No Electron, no webview, no cross-platform toolkit.
- **Nothing resident by default.** Close the window and your lighting, response time and sleep settings are written to the keyboard, then the process exits.
- **No polling.** Connection status is read when the app opens, when the cable is plugged in or removed (OS device events), and when you ask. Only a visible 2.4 GHz wireless connection is re-read every 30 s.
- **Memory handed back.** When minimized or sent to the background, the whole UI is thrown away and rebuilt on restore.
- **Small dependencies.** Windows: .NET Framework 4.8 that ships with Windows 10/11, no WinForms, no `System.Web.Extensions`, software rendering. macOS: IOKit HID directly, no kernel extension, no driver install.

## Features

| | Windows | macOS |
| --- | :---: | :---: |
| Per-key RGB: palette, hex, multi-select, fill/clear, undo, presets, brightness | ✅ | ✅ |
| 20 lighting effects with speed, direction and palette | ✅ | ✅ |
| Response time (3 levels) and sleep timer (4 options) | ✅ | ✅ |
| Macro recorder and upload to a key *(experimental)* | ✅ | ✅ |
| Connection and battery panel (values as reported by the keyboard) | ✅ | ✅ |
| Profile import/export as JSON, **same file format on both systems** | ✅ | ✅ |
| Close mode: write to keyboard and quit, or stay in tray / menu bar | ✅ | ✅ |
| Portable mode (no install, profile next to the .exe) | ✅ | n/a |
| `--self-test`, `--diagnose`, `--measure` command-line tools | ✅ | ✅ |
| Interface in English and Brazilian Portuguese | ✅ | ✅ |

### Two ways to close

Choose in **Device → App** (Windows) or **Device → When closing F75 Studio** (macOS):

1. **Write to keyboard and quit** *(default).* On close, the app sends the lighting in the last mode you used (custom colors, effect, or RGB off), the response time and the sleep timer, and then exits. Zero background footprint. If the keyboard is unplugged and you had unsaved changes, it asks before quitting.
2. **Stay in the background.** Closing or minimizing hides the window and leaves only a tray icon (Windows) or menu bar icon (macOS). No window, no timers, no USB traffic. The icon menu has *Open*, *Turn RGB off*, *Restore colors*, *Quit and write to keyboard* and *Quit without sending*.

The choice is stored in the profile (`KeepInTray`), so a profile exported on one OS behaves the same on the other.

## Download

Get the latest build from **[Releases](../../releases/latest)**.

| File | System | Notes |
| --- | --- | --- |
| `F75-Studio-Setup-1.0.exe` | Windows 10/11, 64-bit | Per-user installer (no admin), English and Brazilian Portuguese |
| `F75-Studio-Portatil-1.0.zip` | Windows 10/11, 64-bit | Portable: unzip anywhere and run `F75 Studio.exe`; the profile is kept in a `Dados` folder next to it |
| `F75-Studio-1.0.dmg` | macOS 11+, Apple Silicon and Intel | Built by the [Mac workflow](.github/workflows/build-mac.yml); see below |

Connect the keyboard **by USB cable** and close the original vendor software before opening F75 Studio.

### Windows SmartScreen warning

The `.exe` files are not code-signed (a signing certificate costs money). Windows may show *"Windows protected your PC"*. Click **More info → Run anyway**. If you prefer, build it yourself from source; it takes one command.

### macOS Gatekeeper warning

The Mac app is signed ad-hoc only, without a paid Apple Developer ID. If you built it on your own Mac it opens normally. If it came from GitHub, the first time right-click **F75 Studio → Open**, or go to **System Settings → Privacy & Security → Open Anyway**.

## Build from source

### Windows

Requirements: Windows with .NET Framework 4.8 (built in on Windows 10/11). Inno Setup 6 only if you want the installer.

```powershell
cd windows\source
powershell -ExecutionPolicy Bypass -File .\build.ps1   # -> windows\F75 Studio.exe and F75 Diagnostics.exe
# optional installer: compile windows\source\installer.iss with Inno Setup 6
```

It uses the `csc.exe` compiler that comes with .NET Framework, so Visual Studio is not required.

### macOS

Requirements: Apple Command Line Tools (`xcode-select --install`). Xcode is not required.

```sh
cd mac
./build.sh        # -> mac/build/F75 Studio.app and mac/build/F75-Studio-1.0.dmg
```

`build.sh` runs the core tests, checks the USB packets are identical to the Windows version, compiles a universal binary (arm64 + x86_64), signs it ad-hoc and creates the `.dmg`.

**No Mac?** Run the **Build F75 Studio for Mac** action in the Actions tab and download the `.dmg` artifact.

### Core tests (any OS)

```sh
sh mac/tests/run-linux.sh                          # C core self-test + golden packet diff
WINSRC="$PWD/windows/source" sh mac/tests/run-linux.sh   # also re-runs the Windows C# code with mono and diffs it
```

These run automatically in the **Core tests** workflow on every push.

## Repository layout

```
windows/
  source/        C# / WPF app (App.cs UI, Device.cs USB HID, Json.cs, Layout.cs, Native.cs tray + color picker)
  tools/         medir-ram-cpu.ps1: measure idle RAM/CPU of F75 Studio vs. the vendor app
  LEIA-ME.md     user guide (Portuguese, with an English summary)
  PROTOCOLO.md   USB protocol notes and known limits (Portuguese)
mac/
  core/          protocol, 81-key layout, profile JSON and self-test in portable C99
  mac/           AppKit UI (F75App.m, F75Views.m) and IOKit HID transport (F75HID.m)
  tests/         golden packets generated by the Windows C# code, compared byte for byte
  build.sh       one-command build to .app and .dmg
.github/workflows/  Mac build and core tests
```

The protocol and profile format are shared. The macOS `core/` is a C port of the Windows protocol code and is verified against it byte for byte (325 lines of packets and JSON). The UIs stay native on purpose, because that is what keeps them light.

## How it talks to the keyboard

F75 Studio speaks to the keyboard over USB, interface `VID 1A2C / PID A073`, vendor HID page `FF02:0002`, using 64-byte reports with the header `AA 55 CC 33`. The command set (lighting `07`, custom RGB `0B` + `F6`–`FB`, sleep `0C`, response time `0D`, macros `00`–`02`, status `0E`) was worked out for interoperability; details and confidence levels are in [`windows/PROTOCOLO.md`](windows/PROTOCOLO.md). Only commands that are understood are sent. Unknown commands are never tried on your keyboard.

## What has and has not been tested

Being upfront, because this is a hobby project tested on one keyboard:

**Tested**
- On a real F75 by USB (Windows, version 0.6, the predecessor of 1.0): connection, status reading and **per-key RGB** work; the UI ran through all pages without errors; idle CPU about 31 ms per 5 s.
- Windows 1.0 compiles to the released binaries; its 16 offline protocol self-checks passed on 0.6, and the protocol code is unchanged in 1.0.
- The C core passes 35 checks with clang and gcc (also under AddressSanitizer and UBSan), and its packets and JSON match the Windows C# code byte for byte.

**Not yet tested**
- The macOS app has **not yet been compiled or run on a Mac** (the Apple SDK only exists on macOS). The Objective-C passed a syntax and type check only. Expect the first Mac build to need fixes; reports are very welcome.
- USB on macOS has not been tried with the keyboard.
- Windows 1.0 lightness changes have not yet been measured on hardware. RAM/CPU savings versus the vendor app are a goal, not a measured claim yet. `windows/tools/medir-ram-cpu.ps1` and `--measure` are there so anyone can check.
- Lighting effects, response time, sleep and macros were derived from the protocol but not physically confirmed; **macros are experimental**.
- Bluetooth and 2.4 GHz: configuration is USB only. The wireless receiver can be queried read-only for status.

**Known limits**
- The white side light bar has no known separate command, so the app does not offer a control for it.
- No evidence yet that every setting survives a keyboard power cycle.

## Contributing

Bug reports, Mac build logs, `--measure` results and protocol findings are all welcome. Please open an issue with your OS version and what you saw. If you own an F75, testing effects, sleep and macros on real hardware helps the most.

## License

[MIT](LICENSE) © 2026 Anglersondev

FREE WOLF is a trademark of its respective owner. This project is not affiliated with it.
