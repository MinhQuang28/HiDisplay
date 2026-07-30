# Private API allowlist

Every undocumented symbol the app depends on, why it is unavoidable, and what happens when it goes
away. Nothing here may be added without a corresponding entry.

The rule from the implementation plan (§2.2): private APIs are permitted, but only at the lowest
transport layer, only resolved at runtime with `dlsym`, and only with a working degrade path. All
lookups go through one function — `Sources/HiDisplayKit/PlatformShims/SymbolResolution.swift` — so the
set of undocumented dependencies is exactly the set of call sites there.

## Why public APIs are not sufficient

HiDisplay targets Apple Silicon only. The Intel column is kept for contrast: on Intel every one of these
had a public answer, which is precisely why the Apple Silicon versions are undocumented rather than
merely obscure.

| Capability | Intel (not supported) | Apple Silicon |
| --- | --- | --- |
| DDC/CI I2C | `IOI2CSendRequest` via `IOFramebuffer` (in the SDK) | **`IOAVService*` — not in the SDK** |
| Built-in display brightness | `IODisplaySetFloatParameter("brightness")` (in the SDK) | **`DisplayServicesSetBrightness` — private framework** |
| Display product metadata | `IODisplayConnect` + `IODisplayEDID` (in the SDK) | `DisplayAttributes` on DCP nodes — a plain IORegistry property read, **no private symbol needed** |

Note the third row: reading Apple Silicon display metadata is *not* a private-API problem. It is an
ordinary `IORegistryEntryCreateCFProperty` call against a differently-named service. That is why
Milestone A needs no shim at all.

## Allowlist

### IOKit — `IOAVService*`

**Framework:** `/System/Library/Frameworks/IOKit.framework/IOKit`
**Shim:** `PlatformShims/IOAVServiceShim.swift`
**Used by:** `Brightness/DDC/AppleSiliconAVServiceTransport.swift`

| Symbol | Assumed signature |
| --- | --- |
| `IOAVServiceCreateWithService` | `(CFAllocatorRef, io_service_t) -> IOAVServiceRef` |
| `IOAVServiceReadI2C` | `(IOAVServiceRef, uint32 chip, uint32 offset, void*, uint32) -> IOReturn` |
| `IOAVServiceWriteI2C` | `(IOAVServiceRef, uint32 chip, uint32 offset, const void*, uint32) -> IOReturn` |

**Evidence level:** experimental observation. Signatures reconstructed from widely-deployed
open-source implementations (MonitorControl and derivatives) plus symbol inspection. **Not Apple
documentation.**

**Verified present:** macOS 26.5.2 (25F84), arm64 — all three symbols resolve.

**Binding verified:** with an external display attached, `IOAVServiceCreateWithService` succeeds
against the correct `DCPAVServiceProxy` node.

**A successful DDC transaction is verified on hardware.** On a ViewSonic VX2780-2K over direct
DisplayPort (macOS 26.5.2), Get VCP 0x10 returns checksum-valid replies and Set VCP 0x10 changes the
backlight with correct read-back — after two framing corrections: the leading 0x51 host-address byte
is link-dependent (the monitor's DP 1.1 mode flips which shape answers), and reply checksums seed
from 0x50, not 0x51. Both captured frames are golden-value tests in `VCPCodecTests`. Full narrative
in `Tests/HardwareMatrix/results.md`.

One earlier display — a Realtek USB-C path with an empty product name and a placeholder serial
(`0x01010101`) — fails every chip/offset combination identically and immediately with `0xe0114000`
(an IOKit error in DCP's own subsystem `0x114`, not the general `kIOReturn*` range). Identical
immediate failure in both directions is the signature of a link that carries video but no I2C — an
adapter or dock, not a monitor exposing its scaler. The transport reports that reason and the
resolver falls back to gamma dimming, which is the degrade path working as designed.

**Degrade path:** `isAvailable` is false if any of the three is missing; the transport reports
`.unsupported`; `BrightnessControllerResolver` falls through to gamma, then shade dimming.

### DisplayServices

**Framework:** `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`
**Shim:** `PlatformShims/DisplayServicesShim.swift`
**Used by:** `Brightness/Native/NativeBrightnessController.swift` — which the **app no longer selects**.
The only panel these symbols work on is the built-in one, and HiDisplay leaves that to macOS (see
`docs/architecture.md`). What remains is `hidisplay-probe` reporting what DisplayServices *would* do,
plus the shim-resolution status in Diagnostics. Kept rather than deleted because it is the evidence
behind the row below, and because that decision is a policy choice, not a limitation of the code.

| Symbol | Assumed signature | Required? | macOS 26.5.2 |
| --- | --- | --- | --- |
| `DisplayServicesGetBrightness` | `(CGDirectDisplayID, float*) -> int` | yes | **present** |
| `DisplayServicesSetBrightness` | `(CGDirectDisplayID, float) -> int` | yes | **present** |
| `DisplayServicesBrightnessChanged` | `(CGDirectDisplayID, double) -> void` | no | **ABSENT** |

**Verified on hardware:** `DisplayServicesGetBrightness(CGMainDisplayID(), &v)` returned status `0`
with value `0.5` on a MacBook Pro Liquid Retina XDR panel, macOS 26.5.2 arm64.

`DisplayServicesBrightnessChanged` **does not exist on macOS 26**. It was treated as optional from the
start precisely because it is a nicety (it nudges the brightness HUD), and that decision is what keeps
native brightness working on this OS version. Had it been required, native brightness would be dead on
current macOS. This is the concrete argument for the "required vs. nice-to-have" split in every shim.

**Known behaviour to design around:** `DisplayServicesSetBrightness` does not persist into system
preferences, so Control Center can overwrite it. Reading back a different value is therefore not an
error and must not be treated as a failed write.

**Degrade path:** if either required symbol is missing, native brightness reports unsupported. Nothing
in the app depends on it today, so the practical effect is one line in the diagnostics report.

## Observed-but-undocumented data layouts

Not private *symbols*, but equally undocumented, so held to the same standard.

### `DisplayAttributes` on DCP service nodes

**Read by:** `Identity/AppleSiliconDisplayMetadataBackend.swift`
**Service classes tried, in order:** `DCPAVServiceProxy`, `AppleCLCD2`, `IOMobileFramebufferShim`

**Verified on macOS 26.5.2 with an external display attached: it is on `AppleCLCD2`.**
`DCPAVServiceProxy` carries **no** `DisplayAttributes` at all — the opposite of what community
documentation describes. The ordered candidate list is what saved this; a single hard-coded class would
have found nothing.

Expected shape:

```
DisplayAttributes = {
    ProductAttributes = {
        ManufacturerID = "DEL";
        LegacyManufacturerID = 4268;
        ProductID = 53409;
        SerialNumber = 0;               // often absent or zero
        ProductName = "DELL U2723QE";
        NativeFormatHorizontalPixels = 3840;
        NativeFormatVerticalPixels = 2160;
    };
}
```

**With no external display attached**, `ioreg` contains zero occurrences of `DisplayAttributes` and no
`DCPAVServiceProxy` nodes — these are created per external display. The app handles that correctly: it
logs `no metadata backend returned records; falling back to CoreGraphics only` and builds identities from
CoreGraphics fields alone.

**Real values read from an attached external display** (macOS 26.5.2):

```
ProductAttributes = {
    ManufacturerID = "RTK";  LegacyManufacturerID = 19083;  ProductID = 9568;
    SerialNumber = 16843009; ProductName = "";  YearOfManufacture = 2023;
}
```

Two things this exposed that the fixtures had not:

- **`ProductName` can be empty.** The name falls back to `Display 4A8B:2560`, which is the same
  identifier that names the override directory and therefore more useful than "Unknown Display".
- **`NativeFormatHorizontalPixels`/`VerticalPixels` can be absent.** Both are optional; native size
  falls back to the largest reported display mode.

**And one that was a real bug:** the built-in panel reports `ProductID = 62896309613633`, which does not
fit a `UInt32`. `registryUInt32` truncated it to `0x30313441` — a plausible-looking value that then
disagreed with CoreGraphics' product ID and silently stopped the built-in display pairing with its own
registry record (`pairing = unmatched`). It now returns `nil` on overflow, so the matcher falls back to
the fields it can trust. Covered by `RegistryValueCoercionTests`.

**Degrade path:** every key is optional and every type is checked. A renamed or restructured layout
lowers the identity key tier (`strong` → `weak`/`location`) instead of crashing.

### Joining the metadata node to the DDC node

`DisplayAttributes` is on `AppleCLCD2`; `IOAVServiceCreateWithService` only accepts a
`DCPAVServiceProxy`. No property joins them. Their ancestors are named consistently, and that is the join:

```
dispext0@8000000               → AppleCLCD2         (has DisplayAttributes)
dispext0:dcpav-service-epic:0  → DCPAVServiceProxy  (is the IOAVService source)
```

`IORegistryAccess.displayUnitToken` walks up the IOService plane and extracts the token before `@` or
`:`. Matching on it is what stops a DDC command reaching the wrong monitor, and `dispext*` versus
`disp*` also distinguishes external from built-in — needed because `Location` is absent on `AppleCLCD2`.

Passing the wrong node to `IOAVServiceCreateWithService` returns null silently, which presented as "no
DDC transport could bind" and looked like a hardware limitation. Covered by `DisplayUnitTokenTests`.

`AppleSiliconAVServiceTransport.unitTokens` scans the same ordered candidate classes as the metadata
backend (`DCPAVServiceProxy`, then `AppleCLCD2`, then `IOMobileFramebufferShim`) rather than
hard-coding the macOS 26 location: community documentation for earlier releases puts
`DisplayAttributes` on `DCPAVServiceProxy`, and a transport pinned to one class would silently
disable DDC on the releases using the other.

### `scale-resolutions` entry encoding

Documented in full in [hidpi-overrides.md](hidpi-overrides.md), including the survey of 252 real
override files that corrected an earlier wrong assumption about the format.

## Enforcement

`SymbolResolution.swift` is the only place `dlsym` is called. To check nothing has crept in:

```sh
grep -rn 'dlsym(\|dlopen(' Sources/ | grep -v 'PlatformShims/'
```

That command must produce no output. Any new symbol requires an entry in this file first.

## Known OS regressions affecting the degrade path

- **`CGSetDisplayTransferByFormula`/`ByTable` do nothing on M5 Pro, M5 Max and MacBook Neo from
  macOS 26.3.1** (Apple bug FB22273730 — confirmed reproduced by DTS, open as of July 2026; affects
  BetterDisplay, MonitorControl, f.lux, Lunar alike). The calls return success and read back the
  values they wrote, but the display does not change — so the failure is invisible to return-code
  checks, and on affected machines the DDC → gamma fallback silently has no effect. Shade dimming is
  unaffected. Gamma verified working on this project's dev machine (not an affected model). If user
  reports of "gamma dimming does nothing" arrive from that hardware, prefer shade over gamma there;
  the suggested workaround in the Apple forums thread is `ColorSyncDeviceSetCustomProfiles`, which
  takes a different pipeline path. Reference: https://developer.apple.com/forums/thread/819331

## What is deliberately *not* used

- **`CGSDisplay*` / SkyLight private APIs** — not needed; `CGSetDisplayTransferByFormula` is public and
  sufficient for gamma dimming.
- **Private APIs for flexible scaling** — deferred past the MVP behind a feature flag, per the plan.
- **`SMJobBless`** — deprecated. The privileged helper will use `SMAppService` (macOS 13+).
