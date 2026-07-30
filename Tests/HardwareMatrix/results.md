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

## Second external display — ViewSonic VX2780-2K

Same Mac and macOS, lid closed (the built-in panel does not enumerate). Vendor `0x5A63`, product
`0x003F`, serial `0x01010101`, native 2560 × 1440, 170 Hz, 1284 modes / 747 HiDPI. The 747 come from a
**third-party** override already present at `DisplayVendorID-5a63/DisplayProductID-3f` (242 entries,
dated before this project touched the machine) — not from HiDisplay, and not evidence its generator
works on a second panel.

### DDC: works, after two framing bugs

The first hardware to complete a real DDC transaction. `Transport = {Upstream=DP, Downstream=DP}`,
direct cable, no hub. Getting here took a wire-format sweep, because both bugs presented as a display
that answers `6E 80 BE` — a spec-compliant **null message**, which is also exactly what a display
sends when DDC/CI is disabled in its OSD. Every plausible external cause was eliminated first:

| Ruled out | How |
| --- | --- |
| Wrong AV service node | exactly 1 `DCPAVServiceProxy`, `Location = External` |
| Reply timing | delay swept 50 / 100 / 200 ms, 4 consecutive reads per write — null 12/12 |
| Read length | 11 vs 12 bytes identical; the 3 bytes simply repeat |
| DDC/CI off in the OSD | user switched it On — no change |
| A competing DDC client | no BetterDisplay/MonitorControl/Lunar running; HiDisplay itself quit — no change |
| The cable path | DP upstream and downstream, no USB hub present |

**Bug 1 — the frame shape was hard-coded, and it is not a constant.** `IOAVServiceWriteI2C` takes the
sub-address as an argument (0x51); DDC/CI frames begin with the same byte. Whether the driver emits it
itself depends on the link, so sending the frame whole is right in one DisplayPort mode and wrong in
the other. Toggling only the monitor's own "DisplayPort 1.1" OSD setting flips the answer:

| DP 1.1 | frame that gets a reply |
| --- | --- |
| on | `82 01 10 AC` — host address dropped |
| off | `51 82 01 10 AC` — sent whole |

The first fix shipped in 0.6.0 dropped the byte unconditionally, on evidence gathered entirely in the
DP 1.1 mode. It worked, and then stopped the moment the user turned that setting off for a sharper
picture. 0.6.1 sends one shape, and on a null message sends the other and adopts whichever answers.

**Methodology note.** The measurement that first appeared to show the flip was invalid: the probe and
the sweep were launched concurrently and both drove the same I2C bus, which is not shareable. Re-run
alone it held. Never sweep the bus with anything else on it, including this app.

**Bug 2 — the reply checksum seed was 0x51, not 0x50.** Latent behind bug 1: once real frames arrived,
every one would have been thrown away as corrupt. 0x51 is the host address a display reads from, 0x50
the one it writes to, and replies are seeded with the latter.

| Item | Result |
| --- | --- |
| Sweep, DP 1.1 **on**: frame with leading 0x51, chip 0x37 / offset 0x51 | `6E 80 BE` — null |
| Sweep, DP 1.1 **on**: frame without leading 0x51, chip 0x37 / offset 0x51 | **`6E 88 02 00 10 00 00 64 00 4B 8B`** |
| Sweep, DP 1.1 **off**: frame with leading 0x51, chip 0x37 / offset 0x51 | **`6E 88 02 00 10 00 00 64 00 3A FA`** |
| Sweep, DP 1.1 **off**: frame without leading 0x51, chip 0x37 / offset 0x51 | `6E 80 BE` — null |
| Offset 0x00 (either shape, either mode) | `6E 80 BE` — null |
| Chip address 0x6E (either shape) | `IOReturn -535740416`, no transfer |
| Decoded replies | 75/100 and 58/100, both checksum-valid against seed 0x50 |
| `Set VCP 0x10 = 40`, read back (DP 1.1 on) | **40** (was 75) |
| `Set VCP 0x10 = 45`, read back (DP 1.1 off) | **45** (was 58) — after shape learning |
| Controller chosen | **`DDC`**, not gamma, in both modes |

Both captured frames are now golden-value tests in `VCPCodecTests`, so a future refactor that shifts
the frame fails in CI instead of on someone's desk.

### Still not verified

| Item | Why |
| --- | --- |
| Monitor ranges other than 0–100 | both this display's max is 100; a 0–255 or 0–64 panel is untested |
| DDC on a display behind a hub or dock | this one is a direct DP link |
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
| Apple Silicon | 26.5.2 | USB-C → DP | direct | ViewSonic VX2780-2K (0x5A63/0x003F) | **works** | **works** (set + read-back) | untested | TBD | frame shape is link-dependent; see section above |
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
