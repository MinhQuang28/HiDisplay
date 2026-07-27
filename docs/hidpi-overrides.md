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
- An override only takes effect when WindowServer next starts, i.e. at the next login. **A logout is
  enough; a restart is not required.** The app offers both and never kills WindowServer itself.

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

### What HiDisplay emits, and why

Only the one form a working generated override is known to use:

- HiDPI: 16 bytes, marker `0x00000001`, flags `0x00200000`.
- 1×: 8 bytes.

Marker `0x1` rather than `0x9` because it is what long-standing open-source HiDPI tooling emits and is
also present in Apple's own files, making it the most field-proven of the observed values.

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
logical size larger than the panel's native pixels, more than 32 resolutions, and a malformed patched
EDID.

It warns but allows: aspect ratio mismatched with the panel, odd dimensions in a HiDPI mode, a backing
store more than twice the panel's pixels (which can cost refresh rate), and any use of EDID injection.

Warnings do not block. The user is allowed to try an unusual resolution on their own hardware — they are
told what is unusual about it first.

## Installing

Milestone B ships the generator only. `HiDPISettingsTab` writes the override file plus a recovery
package into `~/Downloads` and shows the three commands to install it. Nothing outside `~/Downloads` is
written.

`OverrideInstaller` — plan, apply with rollback, restore, remove-app-owned — is complete and tested
against a temporary root, but is not yet wired to the real path because that needs a privileged helper
registered via `SMAppService`, which needs a notarized build. See [security.md](security.md).
