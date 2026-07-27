# Source audit

Which external sources informed this codebase, under what licence, and what was actually taken from each.

The summary: **no source code was copied from any project.** What was reused is factual knowledge about
undocumented macOS interfaces — symbol names, byte layouts, registry key names — which is not copyrightable
expression. Every line here is original, and the primary evidence for the undocumented parts is direct
observation of this machine rather than any third-party implementation.

## Sources consulted

### MonitorControl

- <https://github.com/MonitorControl/MonitorControl>
- Licence: MIT
- **Read:** yes, for the existence and shape of the Apple Silicon DDC path.
- **Reused:** the *knowledge* that `IOAVServiceCreateWithService` / `IOAVServiceReadI2C` /
  `IOAVServiceWriteI2C` exist in IOKit and are the working route on Apple Silicon; that the DDC chip
  address is `0x37` and the data offset `0x51`; that `DisplayServicesSetBrightness` is what controls a
  built-in Apple Silicon panel.
- **Not reused:** no code. `IOAVServiceShim`, `AppleSiliconAVServiceTransport`, `VCPCodec` and
  `DDCCommandQueue` were written from the MCCS framing description and differ structurally — this project
  puts framing in a pure codec, uses one actor per display with a coalescing drain loop, and refuses to
  bind when two monitors are indistinguishable.
- **Verified independently:** all three symbols confirmed present on macOS 26.5.2 by `dlsym`
  (see `docs/private-apis.md`), and `DisplayServicesBrightnessChanged` confirmed **absent** — a divergence
  from what community implementations assume.

### one-key-hidpi

- <https://github.com/xzhih/one-key-hidpi>
- Licence: MIT
- **Read:** yes, for the display-override approach.
- **Reused:** the knowledge that `/Library/Displays/Contents/Resources/Overrides` is the writable override
  root; the `DisplayVendorID-<hex>/DisplayProductID-<hex>` naming; that `scale-resolutions` entries encode
  backing pixels with a HiDPI flag word.
- **Not reused:** nothing. That project is a shell script; this is a Swift module with validation, a
  preview, a backup manifest and rollback. The architecture is explicitly *not* an extension of it.
- **Corrected it:** the marker/flag combination is more varied than a single fixed form. A survey of 3145
  entries across 252 real override files on macOS 26.5.2 found four entry lengths and at least three marker
  values — so this codebase preserves unrecognised entries byte-for-byte instead of normalising them. See
  `docs/hidpi-overrides.md`.

### BetterDisplay

- <https://github.com/waydabber/BetterDisplay>
- Licence: proprietary; public repository is issues and documentation, not source.
- **Read:** documentation and issue discussions only, for the general problem space (which connections
  block DDC, which displays misbehave).
- **Reused:** nothing. No source was available to reuse, and none was sought.

### Apple documentation

- <https://developer.apple.com/documentation/coregraphics>
- <https://developer.apple.com/documentation/coregraphics/cgdisplaymode>
- <https://developer.apple.com/documentation/servicemanagement/smappservice>
- **Reused:** the public CoreGraphics, IOKit registry, and ServiceManagement APIs as documented.

### VESA MCCS

- The DDC/CI command framing (`Set VCP Feature` `0x03`, `Get VCP Feature` `0x01`, XOR checksum seeding,
  the ~40 ms reply delay, brightness as VCP `0x10`) is from the published MCCS standard, which is a
  specification of a wire protocol rather than software.

## Primary evidence gathered on this machine

The undocumented parts rest on direct observation, not on trusting a community implementation:

| Claim | How verified | Result |
| --- | --- | --- |
| `IOAVService*` symbols exist | `dlsym` against IOKit, macOS 26.5.2 arm64 | all three present |
| `DisplayServicesGetBrightness` works | called for `CGMainDisplayID()` | status 0, value 0.5 |
| `DisplayServicesBrightnessChanged` exists | `dlsym` | **absent on macOS 26** |
| Override root is writable | `ls -la /Library/Displays/Contents/Resources/Overrides` | exists, `root:wheel`, already populated |
| Path naming is lowercase unpadded hex | macOS's own `DisplayVendorID-610/DisplayProductID-1f4` | confirmed |
| Plist IDs are decimal while paths are hex | real file: dir `…-5a63`, plist `23139` | confirmed |
| `scale-resolutions` layout | survey of 3145 entries in 252 real files | four lengths, three marker values |
| 16-byte form stores backing pixels | `00001000 00000900 …` = 4096×2304 → 2048×1152 logical | confirmed |

Four real override files are committed under `Tests/HiDisplayTests/Fixtures/overrides/` — three
Apple-supplied and one installed by a third-party tool. They are configuration data describing display
timings, contain no personal information, and are used to prove the codec round-trips real-world data
rather than only its own output.

## Fixtures deliberately *not* committed

A captured EDID from a real monitor. It contains that monitor's serial number, and committing it would
contradict the project's own diagnostics privacy rules. `Fixtures.makeEDID()` assembles a valid synthetic
block instead.

## Licence

HiDisplay is source-available under the PolyForm Noncommercial License 1.0.0 (see `LICENSE.md`). The
consulted MIT-licensed projects impose no obligation here because no code was copied; they are credited in
`THIRD_PARTY_NOTICES.md` regardless, because the knowledge was genuinely useful.
