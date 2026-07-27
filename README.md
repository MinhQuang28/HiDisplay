# HiDisplay

A menu-bar app for macOS 13+ that does two things macOS leaves out: **HiDPI resolutions on displays that
don't get them**, and **brightness control for external monitors**.

Open source, no dependencies, no background daemon, and nothing that requires disabling SIP.

## Status

Milestones A–E of the [implementation plan](#project-layout) are done. What works today:

| | Status |
| --- | --- |
| Display discovery, hot-plug, stable per-monitor identity | working |
| Diagnostics export | working |
| HiDPI override generator, validator, preview, recovery package | working |
| Installing an override — one authorization prompt, backup first, hash-verified after | working |
| Resolution and refresh-rate switching, with a countdown that reverts itself | working |
| Brightness: menu-bar sliders, controller selection, fallbacks, emergency reset | working — **external displays only** |
| Brightness keys (F1/F2) redirected to external displays, with an on-screen indicator | working — needs Accessibility permission |
| Launch at login | working |
| Brightness: the built-in panel | **deliberately not touched** — macOS owns it ([why](#brightness)) |
| Brightness: DDC/CI on Apple Silicon | binds correctly on hardware; **a real transaction is still unverified** — the only test display has no I2C channel |
| Brightness: DDC/CI on Intel | **not implemented** — falls back to gamma dimming ([why](docs/ddc.md)) |
| Privileged helper via `SMAppService` + XPC | not built — needs a Developer ID and notarization. Installing uses a single system authorization prompt instead ([why that is safe](docs/security.md)) |

The DDC wire format is the honest gap: the transport binds and the app degrades correctly, but no
monitor has yet answered a DDC request, so the framing itself remains unproven. See
[`Tests/HardwareMatrix/results.md`](Tests/HardwareMatrix/results.md) for exactly what has and has not been
confirmed on real hardware — including two silent bugs that only appeared once a display was plugged in.

## Features

### HiDPI overrides

macOS offers crisp scaled resolutions on Retina panels but not on most 1440p monitors, where you get a
choice between "native and small" and "scaled and blurry". HiDisplay generates the display override that
adds the missing modes.

- Presets per panel class (1080p / 1440p / 4K), plus custom sizes.
- Resolutions macOS **already** offers are shown and disabled — no override is proposed where none is needed.
- Every resolution is validated against the panel's real native pixel count before it can be installed.
- The generated plist is shown in full before anything happens.
- A recovery package with a verified restore script is created **first**, including instructions that work
  from a Recovery Terminal.
- Installing shows the whole plan before asking for a password: where the file lands, what is already
  there, what your selection replaces — down to a patched EDID another tool left behind — and the one
  command that undoes it without this app.
- The file is read back and hash-checked afterwards. A privileged write nobody verified is a write whose
  outcome you do not know.
- The parser preserves entries it cannot re-encode byte-for-byte, so nothing is lost to a format this app
  does not understand.

### Brightness

**External displays only.** The built-in panel is left entirely to macOS — it already has the brightness
keys, Control Center and ambient-light adaptation, and a second owner of that value can only fight them.
It is also the one screen you cannot unplug, which makes it the worst place to leave a display dimmed by
software. HiDisplay shows it in the menu for its resolution picker and nothing else.

- A slider per external display in the menu bar.
- Automatic controller selection: DDC → gamma → shade overlay, with a per-display manual override.
- Works on monitors with no DDC at all, via gamma or a shade overlay.
- **Reset Dimming** is always one click away in the menu, never behind a submenu — that is the command you
  need when the screen is too dark to navigate.
- Brightness is remembered per monitor and restored on reconnect, after a grace period so a display that
  isn't ready yet doesn't get a burst of failed commands.
- **F1 and F2 can drive the external display.** macOS sends them to the built-in panel only. Turn the tap
  on and they adjust whichever display you mean — under the pointer, the main one, or all of them — with
  an on-screen indicator. A press that concerns the built-in panel is passed straight through, so macOS
  keeps its own behaviour and HUD. Needs Accessibility permission; without it everything else still works.

### Identity that survives reconnects

`CGDirectDisplayID` changes across replugs and reboots, and many external displays on Apple Silicon report
serial number `0` — so two identical monitors naively collapse onto one profile and fight over settings.
HiDisplay keys profiles on a tiered stable identity, tells you which tier a display got and what that
costs, and lets you pin an identity manually when it genuinely cannot tell two monitors apart.

## Requirements

- macOS 13.0 (Ventura) or later.
- Apple Silicon recommended. Intel works for HiDPI and software dimming; Intel DDC is not implemented.
- No permission is required for the core features — sliders, HiDPI generation and diagnostics all work
  with nothing granted. Two optional things ask: **Accessibility** for the brightness keys, and one
  **administrator prompt** at the moment you install an override. No background daemon, no helper tool.

## Install

### Build from source

Requires Xcode's Swift toolchain. `build-app.sh` finds Xcode via `DEVELOPER_DIR`, so you do **not** need to
run `sudo xcode-select`.

```sh
# Optional: a stable local signing identity, so the signature doesn't change every rebuild.
tools/setup-signing-cert.sh

# Build the menu-bar .app into build/HiDisplay.app
./build-app.sh

open build/HiDisplay.app
```

### Pre-built

Releases are signed with a **local, non-notarized** certificate — there is no Apple Developer ID behind
this yet — so macOS blocks the app on first launch. Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/HiDisplay.app
```

Or: double-click it, then System Settings → Privacy & Security → **Open Anyway**.

## Using it

The app lives in the menu bar with no Dock icon. Click the display icon for per-monitor sliders, a
resolution picker, **Sync Displays**, and **Reset Dimming**. ⌘, opens Settings:

- **General** — launch at login, and a second **Reset All Dimming** for when the menu is too dark to read.
- **Displays** — resolution and refresh rate, which brightness controller each display got, why, and how
  to override it.
- **HiDPI** — generate, validate, preview, install or export an override.
- **Keyboard** — brightness keys: on/off, which display they target, and the Accessibility status.
- **Diagnostics** — export a support report, and see whether the private-API shims resolved on your macOS.

### Installing a generated override

Settings → HiDPI → select resolutions → **Install…**. You get a summary of exactly what will change
before any password prompt; approving it backs the old file up into `~/Downloads`, writes the new one
with a single authorization, and verifies the result by hash.

**Export Only…** is the same thing without the privileged step: it writes the file and the recovery
package to `~/Downloads` and prints the `mkdir` and `cp` commands to run yourself.

To undo either: run `restore.command` inside the recovery folder. Read [docs/recovery.md](docs/recovery.md)
before you install anything — a bad override can mean a black screen at next login, and it is worth
knowing the Recovery Terminal route in advance.

## Development

```sh
swift build
swift test                # 213 tests, no hardware needed
swift run hidisplay-probe # diagnostic CLI: shims, backends, identity, transport, brightness probe
./build-app.sh            # assemble and sign the .app
tools/package-release.sh  # build + zip + sha256 (add --publish for a GitHub release)
```

`hidisplay-probe` is the tool to reach for when brightness misbehaves on a particular monitor: it prints
the whole chain in one pass, including which registry node the DDC channel bound to and the decoded
`IOReturn` if it failed.

Everything hardware-shaped has a fake, so the whole suite runs on a machine with no external display:
`FakeDDCTransport` for I2C, fixture dictionaries for both IORegistry backends, a synthetic EDID, and four
**real** override files captured from macOS to prove the encoder handles real-world data rather than only
its own output.

### Project layout

| Path | Purpose |
| --- | --- |
| `Sources/HiDisplayKit/Core/` | Models, discovery, identity resolution, diagnostics |
| `Sources/HiDisplayKit/PlatformShims/` | The only `dlsym` in the project — see [docs/private-apis.md](docs/private-apis.md) |
| `Sources/HiDisplayKit/Brightness/` | DDC transports, VCP codec, command queue, native/gamma/shade controllers |
| `Sources/HiDisplayKit/HiDPI/` | EDID parser, override generator, validator, installer, recovery package |
| `Sources/HiDisplay/` | Menu bar, Settings, HiDPI tab, app model |
| `Sources/hidisplay-probe/` | Diagnostic CLI |
| `Tests/HiDisplayTests/` | Unit and integration tests, plus fixtures |
| `build-app.sh` | Assemble and sign the `.app` |
| `tools/` | Signing cert, release packaging, icon generation |

There is no committed `.xcodeproj` — SwiftPM is the source of truth. Open `Package.swift` in Xcode for full
IDE support.

### Documentation

- [architecture.md](docs/architecture.md) — layering, identity tiers, concurrency rules
- [ddc.md](docs/ddc.md) — wire format, throttling, why Intel is a stub
- [hidpi-overrides.md](docs/hidpi-overrides.md) — the override format, and the survey of 3145 real entries that corrected it
- [private-apis.md](docs/private-apis.md) — every undocumented symbol, its evidence level, and its degrade path
- [recovery.md](docs/recovery.md) — undoing an override, including from a Recovery Terminal
- [security.md](docs/security.md) — path handling, atomic writes, the future helper's boundaries
- [legal/source-audit.md](docs/legal/source-audit.md) — what was learned from where

## Design notes worth knowing

**Private APIs are used, deliberately and narrowly.** DDC on Apple Silicon and built-in brightness have no
public route. Those symbols are resolved at runtime through a single function, each with an entry in
`docs/private-apis.md` and a working fallback. `DisplayServicesBrightnessChanged` was already removed in
macOS 26 — the app kept working because it was treated as optional from the start.

**Undocumented formats are verified, not assumed.** An early draft of the override encoding was simply
wrong; a survey of every override file on a real macOS install found four entry lengths where one was
expected. The codec now preserves anything it cannot explain, and a test round-trips real files
byte-for-byte.

**Hardware finds what fixtures cannot.** Plugging in one external display exposed two silent bugs: DDC
bound to the wrong registry node (`IOAVServiceCreateWithService` just returns null), and a `UInt32`
overflow in a registry value stopped the built-in display pairing with its own record. Neither crashed;
both looked like hardware limitations. Both now have regression tests.

**The installer cannot touch the real path from a test.** Its filesystem root is injected with no default.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md):

- Free for personal, noncommercial use — install it, read it, modify it, build it, share it for free.
- Commercial use is not permitted without a separate license from the author.

No third-party code is included; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright © Ha Minh Quang.
