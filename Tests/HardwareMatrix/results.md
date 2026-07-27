# Hardware test matrix

Manual results. Not run in CI — the automated suite uses fakes and fixtures for everything hardware-shaped.

Fill one row per Mac + macOS + connection + monitor combination. `TBD` means untested, not "works".

## Development machine

| Field | Value |
| --- | --- |
| Mac | MacBook Pro, Apple Silicon (`disp0,t8122`) |
| macOS | 26.5.2 (25F84), arm64 |
| Displays attached | Built-in Liquid Retina XDR (3024 × 1964) + one external, 2560 × 1600 @ 60 Hz |
| External display | Realtek USB-C path — vendor `0x4A8B` ("RTK"), product `0x2560`, serial `0x01010101`, empty product name, 2023 |

### Verified

| Item | Result |
| --- | --- |
| App launches, menu bar item appears | pass |
| `swift build` clean, zero warnings | pass |
| `swift test` — 213 tests | pass |
| `dlsym IOAVServiceCreateWithService` | **found** |
| `dlsym IOAVServiceReadI2C` | **found** |
| `dlsym IOAVServiceWriteI2C` | **found** |
| `dlsym DisplayServicesGetBrightness` | **found** |
| `dlsym DisplayServicesSetBrightness` | **found** |
| `dlsym DisplayServicesBrightnessChanged` | **ABSENT on macOS 26** — treated as optional, so native brightness still works |
| `DisplayServicesGetBrightness(main)` | status 0, value 0.5 — works on the XDR panel |
| `/Library/Displays/Contents/Resources/Overrides` writable root exists | pass — `root:wheel`, already contained a third-party override |
| Override path naming (lowercase unpadded hex) | pass — matches macOS's own files |
| `scale-resolutions` codec round-trips real files | pass — 3145 entries across 252 files |
| Metadata backend with no external display | degrades correctly — logs `no metadata backend returned records; falling back to CoreGraphics only` |
| Metadata backend **with** an external display | reads 2 records off `AppleCLCD2` |
| `DisplayAttributes` node on macOS 26 | **`AppleCLCD2`, not `DCPAVServiceProxy`** — the latter has none |
| Display unit token join (`dispext0`) | works — links the metadata node to the AV service node |
| `IOAVServiceCreateWithService` on the correct node | **succeeds** |
| External display identity | tier `strong` (serial present), pairing `confident` |
| Built-in display identity | tier `strong`, pairing `confident` (was `unmatched` before the overflow fix) |
| Gamma dimming on the external display | **works** — `CGSetDisplayTransferByFormula` succeeded, restored cleanly |
| Controller chosen for the external display | `Gamma (software)` — correct given no I2C |
| Empty `ProductName` handling | falls back to `Display 4A8B:2560` |

### Bugs this hardware session found

Both were silent — nothing crashed, and both presented as hardware limitations.

1. **DDC could never bind.** The transport passed the `AppleCLCD2` node (which carries
   `DisplayAttributes`) to `IOAVServiceCreateWithService`, which only accepts `DCPAVServiceProxy` and
   returned null. Reported as "no DDC transport could bind to this display". Fixed by joining the two
   nodes on their shared display unit token. Covered by `DisplayUnitTokenTests`.
2. **The built-in display never paired with its registry record.** It reports
   `ProductID = 62896309613633`, which `registryUInt32` truncated to `0x30313441` — a plausible-looking
   value that then disagreed with CoreGraphics and blocked the match (`pairing = unmatched`). Now returns
   `nil` on overflow. Covered by `RegistryValueCoercionTests`.

### DDC on this external display: no I2C channel

Every combination fails identically and immediately, both directions:

| chip | offset | write | read |
| --- | --- | --- | --- |
| `0x37` | `0x51` | `0xe0114000` | `0xe0114000` |
| `0x37` | `0x00` | `0xe0114000` | `0xe0114000` |
| `0x6E` | `0x51` | `0xe0114000` | `0xe0114000` |
| `0x6E` | `0x00` | `0xe0114000` | `0xe0114000` |

`0xe0114000` = sys_iokit, subsystem `0x114` (DCP's own), code `0`. Not in the general `kIOReturn*` range.

Identical immediate failure across all four combinations and both directions is the signature of a link
carrying video but no I2C, not of wrong framing — a bad chip address and a bad offset would fail
differently, a sleeping monitor would time out, and a framing error would return bytes that fail to
decode. Combined with the empty product name and placeholder serial `0x01010101`, this is an adapter or
dock, not a monitor exposing its scaler.

The app behaves correctly: it reports the reason in plain language and falls back to gamma dimming.

### Still not verified — needs a monitor with a working DDC path

| Item | Why |
| --- | --- |
| A DDC read that returns real data | the only external display available has no I2C channel |
| A DDC write changing actual backlight | same |
| The 11-byte reply layout against real monitor bytes | same — **the framing remains unproven** |
| Monitor ranges other than 0–100 | same |
| Two-identical-monitor ambiguity refusal on real hardware | needs two matching monitors |
| Installing a generated override and seeing the mode appear | needs a restart |
| Refresh rate / HDR retention after an override | same |
| Sleep/wake brightness restoration over DDC | needs a DDC-capable monitor |
| Intel `IOI2CSendRequest` path | not implemented; needs an Intel Mac — see docs/ddc.md |

## Matrix to fill in

| Mac | macOS | Port | Adapter/Hub | Monitor | DDC read | DDC write | HiDPI override | Sleep/wake | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Apple Silicon | 26.5.2 | — | — | Built-in XDR | n/a | n/a | n/a (built-in) | TBD | native brightness works (DisplayServices) |
| Apple Silicon | 26.5.2 | USB-C | Realtek path | 2560×1600 (RTK/0x2560) | **no I2C** (`0xe0114000`) | **no I2C** | untested | TBD | AV service binds; gamma fallback works |
| Apple Silicon | 26 | USB-C → DP | direct | TBD | TBD | TBD | TBD | TBD | |
| Apple Silicon | 26 | USB-C → USB-C | direct | TBD | TBD | TBD | TBD | TBD | |
| Apple Silicon | 26 | HDMI | direct | TBD | TBD | TBD | TBD | TBD | HDMI often blocks DDC |
| Apple Silicon | 15 | USB-C → DP | direct | TBD | TBD | TBD | TBD | TBD | |
| Apple Silicon | 14 | USB-C → DP | direct | TBD | TBD | TBD | TBD | TBD | |
| Apple Silicon | 13 | USB-C → DP | direct | TBD | TBD | TBD | TBD | TBD | minimum supported |
| Apple Silicon | 26 | Dock | DisplayLink | TBD | expect none | expect none | TBD | TBD | should fall back to shade |
Intel Macs are out of scope — the app is Apple Silicon only. See [ddc.md](../../docs/ddc.md).

## What to record per test

- Cable make and model; hub or dock firmware version if any.
- Whether DDC/CI is enabled in the monitor's own OSD menu (many ship with it off).
- Refresh rate and whether it survived an override.
- HDR on/off, and whether it survived.
- Clamshell open/closed.
- Read result, write result, and whether the correct monitor responded when two are attached.
- Brightness restoration after sleep/wake and after replug.
- Attach the diagnostics export (Settings → Diagnostics → Export). It contains no personal data.

## Reproducing these results

```sh
swift run hidisplay-probe          # full chain: shims, backends, identity, transport, probe
swift run hidisplay-probe --set 50 # additionally write a brightness value over DDC
```

## Reproducing the shim check

```sh
swift - <<'EOF'
import Foundation
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
for s in ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C"] {
    print(s, dlsym(h, s) != nil ? "found" : "missing")
}
EOF
```

## Reproducing the override survey

```sh
python3 - <<'EOF'
import plistlib, pathlib, collections
c = collections.Counter()
for root in ["/System/Library/Displays/Contents/Resources/Overrides",
             "/Library/Displays/Contents/Resources/Overrides"]:
    for p in pathlib.Path(root).rglob("DisplayProductID-*"):
        if p.is_dir(): continue
        try: d = plistlib.loads(p.read_bytes())
        except Exception: continue
        if not isinstance(d, dict): continue
        for e in d.get("scale-resolutions") or []:
            b = bytes(e)
            m8 = hex(int.from_bytes(b[8:12], "big")) if len(b) >= 12 else None
            m12 = hex(int.from_bytes(b[12:16], "big")) if len(b) >= 16 else None
            c[(len(b), m8, m12)] += 1
for k, v in sorted(c.items(), key=lambda x: -x[1]): print(k, v)
EOF
```
