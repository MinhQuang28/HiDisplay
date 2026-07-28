# DDC/CI

## One transport: Apple Silicon only

| | Apple Silicon |
| --- | --- |
| Route | `IOAVServiceRead/WriteI2C` |
| In the SDK? | **No** — see [private-apis.md](private-apis.md) |
| Status here | Implemented, unverified on hardware |

### Why there is no Intel transport

HiDisplay supports Apple Silicon only. The Intel route was never implemented, and the stub that used to
report `.unsupported` has been removed along with the rest of the Intel code.

It was not a matter of effort. `IOI2CSendRequest` takes an `IOI2CRequest` struct that is not projected
into Swift, because it contains a function-pointer completion field. Using it needs either a C shim
target or a hand-declared struct layout — and hand-declaring a kernel ABI struct from memory is exactly
the kind of guess that becomes memory corruption when a field order or padding assumption is wrong.

If Intel support is ever wanted back, it needs:

1. A C shim target exposing `IOI2CRequest` and `IOI2CSendRequest` with the **header's own** layout, so
   the ABI comes from the SDK rather than from memory.
2. `IOFramebufferPortFromCGDisplayID`, or a vendor/product match over `IOFramebuffer` services.
3. `IOI2CInterfaceCount` / `IOI2CCopyInterfaceForBus` / `IOI2CInterfaceOpen`, one bus at a time, with the
   connection closed on every exit path.
4. An Intel test machine. Adding it without one would be the same guess in a new place.

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
└────────── host source address — checksummed, NOT transmitted (see below)
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
checksum seeded with 0x50
```

### The host address is checksummed but not sent

The single most expensive detail in this file. `IOAVServiceWriteI2C(service, 0x37, 0x51, data, len)`
takes the sub-address as its third argument and puts that byte on the bus itself. The frames above
*begin* with the same 0x51, because the checksum covers it — but including it in `data` makes the
display receive `51 51 82 01 10 AC`, which it cannot parse.

So the wire bytes are the frame minus its first byte:

```
frame:  51 82 01 10 AC        <- what the checksum is computed over
wire:      82 01 10 AC        <- what IOAVServiceWriteI2C is given
```

A display that cannot parse a request replies with a **null message**, `6E 80 BE`. That is a
well-formed frame with a correct checksum, and it is also what a display sends when DDC/CI is switched
off in its OSD — so a framing bug and a disabled monitor are indistinguishable from the outside. On a
ViewSonic VX2780-2K this cost a full debugging session: OSD toggled, competing apps quit, timing swept
50–200 ms, read lengths 11 and 12, chip 0x37/0x6E, offsets 0x51/0x00 — every combination null, until
the leading byte was dropped and the very first attempt returned
`6E 88 02 00 10 00 00 64 00 4B 8B`.

Reach for `hidisplay-probe --ddc-sweep` before believing a monitor is at fault. It tries both frame
shapes across several chip addresses and offsets and prints raw bytes, decoding nothing.

### Reply checksum seed is 0x50, not 0x51

0x51 is the host address a display *reads from*; 0x50 is the one it *writes to*, and a reply is seeded
with the latter. Seeding with 0x51 rejects every well-formed reply as corrupt. Verify against the real
capture above: those ten bytes XOR to 0xDB, and 0xDB ^ 0x8B = 0x50.

This bug sat latent behind the framing one — no reply ever arrived to be mis-verified.

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
time out rather than reject. So this pattern means the path, not the app.

This section used to add "a framing error would produce a reply that fails to decode". That was wrong,
and believing it wasted a debugging session on the VX2780-2K. A framing error produces a **null
message** — a perfectly well-formed frame with a valid checksum that decodes cleanly and simply
carries no data. It is not distinguishable from a monitor with DDC/CI switched off. `6E 80 BE` means
*the display did not understand the request*, and the request is a thing this app controls.

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
