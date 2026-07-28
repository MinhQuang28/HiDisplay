# Display overrides

## Where overrides live

| Path | Writable | Used by HiDisplay |
| --- | --- | --- |
| `/System/Library/Displays/Contents/Resources/Overrides` | **No** — SIP, read-only system volume | Never. Explicitly rejected by `OverridePaths`. |
| `/Library/Displays/Contents/Resources/Overrides` | Yes, with root | **The only write target.** |

Verified on macOS 26.5.2: `/Library/Displays/Contents/Resources/Overrides` exists, is owned by
`root:wheel`, and already contained a third-party override on the development machine.

Consequences, all enforced in code:

- **SIP never needs disabling.** No code path names the system root; `OverridePaths.resolve` throws
  `.forbiddenRoot` if one ever does.
- The privileged helper's allowlist is exactly one directory.
- An override takes effect when the display is next attached, or when WindowServer next starts at
  login. **Reconnecting an external display is enough and is the fastest route; a logout also works;
  a restart is never required.** The app offers logout and restart and never kills WindowServer
  itself — unplugging a cable is something only the user can do.

  Measured on 2026-07-27: an override written at 21:04 was still not in effect at 21:12 despite a
  logout at 21:02 — because the logout happened *before* the write. Unplugging and reconnecting the
  monitor applied it immediately. Ordering is the whole trap here: whichever route is used, it has to
  come after the file is written.

### Layout

```
/Library/Displays/Contents/Resources/Overrides/
└── DisplayVendorID-<vendor hex, lowercase, unpadded>/
    └── DisplayProductID-<product hex, lowercase, unpadded>
```

Confirmed against macOS's own files: `DisplayVendorID-610/DisplayProductID-1f4`,
`DisplayVendorID-10ac/…`. No file extension, no zero padding.

**The asymmetry that is easy to get wrong:** the path uses **hex**, while `DisplayVendorID` and
`DisplayProductID` *inside* the plist are **decimal**. Vendor `0x5A63` → directory
`DisplayVendorID-5a63`, plist `<integer>23139</integer>`. `OverridePathTests` pins both for the same
display.

## The `scale-resolutions` encoding

Each entry is a `<data>` blob, all fields big-endian.

### What real files actually contain

Surveyed every override file carrying `scale-resolutions` on a macOS 26.5.2 install — 251 Apple-supplied
plus one third-party HiDPI override, 3145 entries total:

| Length | word @8 | word @12 | Count |
| --- | --- | --- | --- |
| 12 | `0x1` | – | 1704 |
| 8 | – | – | 502 |
| 16 | `0x9` | `0x00a00000` | 365 |
| 16 | `0x1` | `0x00200000` | 216 |
| 12 | `0x2` | – | 156 |
| 16 | `0x9` | `0x00200000` | 139 |
| 9 | – | – | 63 |

> An earlier draft of the implementation plan asserted a single fixed 16-byte form with marker
> `0x00000001`. The survey disproved it: there are **four** entry lengths in the wild, the marker word
> takes at least three values, and there is a second flag bit nobody has explained. The plan was
> corrected from this data. This is the reason the project's rule is to capture fixtures before writing
> a generator rather than after.

### Layout

```
offset 0..3    UInt32   width        (backing pixels in the 16-byte form)
offset 4..7    UInt32   height
offset 8..11   UInt32   marker       (12- and 16-byte forms; 0x1, 0x2 or 0x9 observed)
offset 12..15  UInt32   flags        (16-byte form only)
offset 16..    trailing bytes        (the stray 9th byte of the 9-byte form)
```

`0x00200000` in the flags word is the HiDPI bit.

### The 16-byte form stores backing pixels

From the third-party override on the development machine:

```
00001000 00000900 00000009 00200000
   4096      2304   marker  HiDPI
```

4096 × 2304 backing = **2048 × 1152 logical**, a standard scaled size and exactly one of the 1440p
presets. Several other entries in the same file decode the same way (5056 × 2844 → 2528 × 1422 etc.).

### What is known versus guessed

**Known from real files:** the byte layout; that `0x00200000` means HiDPI; that the 16-byte form stores
the backing store; that plist IDs are decimal while paths are hex.

**Not known:** what the marker word means; why `0x1` and `0x9` both appear with identical flags; what
`0x00800000` (the extra bit in `0x00a00000`) does; why some entries carry a stray ninth byte.

**Not documented by Apple at all.** Nothing above is contractual.

### What the encodings actually mean — hardware probe, 2026-07-27

M3, macOS 26.5.2, 2560 × 1600 external panel. One override carrying five backing sizes, each written in
a different encoding, installed and the display reconnected:

| Encoding | Backing written | Mode that appeared |
| --- | --- | --- |
| 8 bytes | 2880 × 1800 | 1440 × 900 HiDPI |
| 12 bytes, marker `0x1` | 3200 × 2000 | 1600 × 1000 HiDPI |
| 16 bytes, marker `0x9`, flags `0x00200000` | 3360 × 2100 | 1680 × 1050 HiDPI |
| 16 bytes, marker `0x1`, flags `0x00200000` | 3840 × 2400 | 1920 × 1200 HiDPI |
| 16 bytes, marker `0x9`, flags `0x00200000` | 1536 × 960 | 768 × 480 HiDPI |

What this **does** show:

1. **A standalone 8-byte entry produces a HiDPI mode**, at half the stored size — `2880 × 1800` came
   back as `1440 × 900 HiDPI`, not as a 1× mode. A standalone 12-byte marker-`0x1` entry behaves the
   same. This is the form Apple's own built-in override uses.
2. **There is no native-size ceiling.** A 3840 × 2400 backing on a 2560 × 1600 panel works — macOS
   supersamples down. Apple's built-in override does the same (`3600 × 2338` on a 3024 × 1964 panel).

What it does **not** show, and was wrongly read as showing:

> Rows C, D and E each carried an 8-byte companion of the same size in addition to the 16-byte entry.
> The probe therefore never tested a 16-byte entry standalone, and could say nothing about whether the
> companion is needed. It was read as proving the four encodings interchangeable and the companion
> redundant; the generator was changed to emit HiDPI entries alone.
>
> **That change produced an override of 64 16-byte entries and zero modes.** The 124-entry file it
> replaced — the same ladder with companions — had produced 61. The pairing is required, the original
> code was right, and the lesson is the one this project already had a rule for: a probe only tells you
> about the combinations it actually varied.

Still open: whether the 16-byte entry contributes anything when its companion is present. Conclusion 1
hints it may not, and an override of 8-byte entries alone might be enough — but that is a *new*
hypothesis needing its own test, not something to infer twice from the same data.

### Scale

A 62-step ladder generated by this app — 124 entries, HiDPI plus companions — installed on the same
display and produced **61 of its 62 modes**. The single casualty was logical 2560 × 1600, a
5120 × 3200 backing, dropped with no error, while 5056 × 3160 one step below was accepted. HiDPI modes
are now capped strictly below the panel size for that reason; see `OverrideValidator`.

### What HiDisplay emits

- HiDPI: 16 bytes, marker `0x00000001`, flags `0x00200000`.
- 1×, and the backing companion paired with every HiDPI entry: 8 bytes.

Marker `0x1` rather than `0x9` because it is what long-standing open-source HiDPI tooling emits and is
also present in Apple's own files.

The app **never invents a form it cannot explain.** Entries in any other shape are passed through
untouched: `ScaleResolutionCodec.decode` returns them with their original marker, flags and trailing
bytes, and `ScaleResolutionEntry.encoded()` reproduces the original bytes exactly. A test round-trips
every entry in every bundled real fixture byte-for-byte.

This matters because a user's override may contain modes written by Apple or another tool. Rewriting the
file must not delete them — `OverrideGeneratorTests.testUnrecognisedEntriesFromARealFileArePreserved`
proves it does not.

### Example output

For vendor `0x10AC`, product `0xD0A1`, one HiDPI mode at 1920 × 1080:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>DisplayProductID</key><integer>53409</integer>
    <key>DisplayProductName</key><string>DELL U2723QE</string>
    <key>DisplayVendorID</key><integer>4268</integer>
    <key>scale-resolutions</key>
    <array>
        <data>AAAPAAAACHAAAAABACAAAA==</data>
    </array>
</dict>
</plist>
```

Written to `DisplayVendorID-10ac/DisplayProductID-d0a1`. XML rather than binary so it can be read and
repaired from a Recovery Terminal with nothing but a text editor.

Output is deterministic: resolutions are sorted by pixel area, so regenerating the same selection
produces byte-identical bytes and a no-op diff.

## EDID injection

`IODisplayEDID` is supported but **off by default**, and the validator warns whenever it is enabled.

On Apple Silicon a patched EDID has little or no effect while measurably raising the risk of a black
screen after wake. A malformed one is rejected outright — the validator requires a correct header and
checksum before those bytes can be written.

## Validation before install

`OverrideValidator` blocks installation on: zero vendor or product ID, empty selection, duplicates,
backing scale other than 1× or 2×, logical size below 640 × 480, backing dimension above 16384, a
logical size larger than the panel's native pixels, more than 128 resolutions
(`OverrideValidator.maximumResolutionCount` — raised from 32 after a real override with 89 modes was
found working), and a malformed patched EDID. A merge is validated against the *union* it will
write, not just the new selection.

It warns but allows: aspect ratio mismatched with the panel, odd dimensions in a HiDPI mode, a backing
store more than twice the panel's pixels (which can cost refresh rate), and any use of EDID injection.

Warnings do not block. The user is allowed to try an unusual resolution on their own hardware — they are
told what is unusual about it first.

## Installing

Two routes, both in `HiDPISettingsTab`:

* **Install** plans against the real `/Library/Displays` root, shows the full plan (destination,
  what is replaced, what is carried over, the undo command), writes a recovery package into
  `~/Downloads`, then performs the privileged copy through `PrivilegedInstaller` after one
  authorization prompt. The privileged script re-verifies the payload's SHA-256 itself before moving
  it into place, and the installed file is read back and verified afterwards.
* **Export Only** writes the same file plus the recovery package into `~/Downloads` and shows the
  commands to install it by hand. Nothing outside `~/Downloads` is written.

`PrivilegedInstaller` currently uses `NSAppleScript`'s administrator prompt rather than a helper
registered via `SMAppService` — the helper remains the intended end state once a notarized build
exists. See [security.md](security.md).
