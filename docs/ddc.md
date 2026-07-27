# DDC/CI

## Two transports, because there is no shared API

| | Intel | Apple Silicon |
| --- | --- | --- |
| Route | `IOFramebuffer` → `IOI2CSendRequest` | `IOAVServiceRead/WriteI2C` |
| In the SDK? | Yes (`IOKit/i2c/IOI2CInterface.h`) | **No** — see [private-apis.md](private-apis.md) |
| Status here | **Not implemented** | Implemented, unverified on hardware |

### Why the Intel transport is a documented stub

`IOI2CSendRequest` takes an `IOI2CRequest` struct that is not projected into Swift, because it contains a
function-pointer completion field. Using it requires either a C shim target or hand-declaring the struct
layout in Swift.

Hand-declaring a kernel ABI struct from memory is exactly the kind of guess that becomes memory
corruption when a field order or padding assumption is wrong. This project's own rule is not to present
assumptions as facts, so `IntelI2CTransport` reports `.unsupported` and says why, and the brightness stack
falls back to gamma dimming on Intel — degraded but correct.

What a real implementation needs, once an Intel test machine exists:

1. A C shim target exposing `IOI2CRequest` and `IOI2CSendRequest` with the **header's own** layout, so
   the ABI comes from the SDK rather than from memory.
2. `IOFramebufferPortFromCGDisplayID`, or a vendor/product match over `IOFramebuffer` services.
3. `IOI2CInterfaceCount` / `IOI2CCopyInterfaceForBus` / `IOI2CInterfaceOpen`, one bus at a time, with the
   connection closed on every exit path.

## Binding to the right monitor

The delicate part is not the I2C call. It is deciding *which* `DCPAVServiceProxy` is the display the
caller means — and the answer is not on that node.

**The metadata and the DDC channel live on different nodes.** On macOS 26.5.2, `DisplayAttributes` (with
vendor, product, serial) is on `AppleCLCD2`, while `IOAVServiceCreateWithService` only accepts a
`DCPAVServiceProxy`, which has no `DisplayAttributes` at all. Handing it the metadata node returns null —
which is exactly what happened the first time this ran on hardware, and it presented as "no DDC transport
could bind", i.e. as though the monitor were at fault.

No property joins the two nodes. Their ancestors are named consistently, and that is the join:

```
dispext0@8000000               → AppleCLCD2         (has DisplayAttributes)
dispext0:dcpav-service-epic:0  → DCPAVServiceProxy  (is the IOAVService source)
```

So `AppleSiliconAVServiceTransport`:

1. Finds which display *units* match the identity, by reading `DisplayAttributes` off `AppleCLCD2` nodes
   and taking each one's unit token (`IORegistryAccess.displayUnitToken`).
2. **Refuses to bind at all** if more than one unit matches — two identical monitors with no serial.
3. Binds the `DCPAVServiceProxy` carrying the same token.

A display with no brightness control is a visible, explainable limitation. A slider that dims the wrong
monitor is not.

The registry-node order is also not guaranteed to match `CGGetOnlineDisplayList`, so nothing here matches
by index.

## Wire format

Constants: chip address `0x37` (`0x6E >> 1`), sub-address `0x51`, host source address `0x51`, display
address `0x6E`.

Set brightness:

```
51 84 03 10 <hi> <lo> <checksum>
│  │  │  └─ VCP 0x10 = brightness
│  │  └──── 0x03 Set VCP Feature
│  └─────── 0x80 | payload length 4
└────────── host source address
checksum = XOR of all preceding bytes, seeded with 0x6E
```

Get brightness request:

```
51 82 01 10 <checksum>
```

Reply, 11 bytes:

```
6E 88 02 <result> 10 <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
 0  1  2     3     4    5       6        7        8        9        10
checksum seeded with 0x51
```

MCCS asks for ~40 ms between request and reply; the code uses 50 ms as a floor and some panels need more.

### Ranges are not 0–100

The maximum comes from the monitor's own reply. 0–255 is common and 0–64 exists. Assuming 0–100 would make
every value on a 0–255 panel wrong by 2.5×.

### Checksums are often wrong

A non-trivial number of monitors compute the reply checksum incorrectly while reporting correct values.
`decodeReply` rejects a bad checksum by default so line noise cannot be read as a brightness value — but
`DDCBrightnessController.probe` retries once with `tolerateChecksumMismatch: true` and, if that succeeds,
remembers the quirk for that display. The returned `Reply` still records `checksumValid: false` so
diagnostics show why a value is suspect.

## Throttling

- `setBrightness` records the value and returns; it never awaits the wire.
- The drain loop writes at most one frame per 40 ms (~25/s).
- Intermediate values are overwritten, not queued — that is the coalescing.
- The loop re-checks after each write, so the final value always lands.
- Writes are never retried: a brightness write is idempotent and superseded a moment later by the next
  slider position, so retrying only adds bus traffic during a drag.
- Reads are retried at most twice, with linear backoff, and only for `.timeout` / `.ioError`.

`DDCCommandQueueTests` asserts all of this against `FakeDDCTransport`, including that 50 rapid values
produce far fewer than 50 writes and that the last one is the value released on.

## Probing must not change what is on screen

`probe` performs one read and never writes a value. Probing by writing-then-reading is how other tools do
it, but it makes plugging in a monitor visibly flicker, and on a monitor that accepts writes while
reporting nonsense it can leave the panel stuck at the probe value.

Probe results are cached per connection session and can be overridden per display in Settings.

## When there is no I2C channel at all

Observed on macOS 26.5.2 through a Realtek USB-C display path: every combination of chip address
(`0x37`, `0x6E`) and offset (`0x51`, `0x00`) fails identically and immediately, on both read and write,
with `0xe0114000`.

That is an IOKit error in DCP's own subsystem `0x114` — not one of the general `kIOReturn*` values, so a
decoder that only knew the standard constants would print "unknown". `IOReturnDescription` recognises it
and says what it means: the connection carries video but no I2C, which is normal for many docks,
adapters, KVMs and virtual displays.

Identical immediate failure across all four combinations, in both directions, is the distinguishing
signature. A wrong chip address and a wrong offset would fail *differently*; a sleeping monitor would
time out rather than reject; a framing error would produce a reply that fails to decode. So this pattern
means the path, not the app.

## Known hardware behaviour to expect

- Some cables, hubs and HDMI adapters block DDC entirely.
- A sleeping monitor does not answer; this is `.timeout`, not `.unsupported`, because it recovers.
- Some monitors answer only after a delay longer than the MCCS minimum.
- Read may work while write does not, or write may work while read returns a stale value.
- A KVM can make the same physical monitor appear with different EDID.
- DisplayLink and AirPlay displays have no DDC bus at all — they fall through to shade dimming.

## Scope

Brightness (`0x10`) only. Contrast, volume, mute, input source and power are deliberately absent from the
MVP so that a bug in this layer cannot mute a monitor or switch it to a dead input.
