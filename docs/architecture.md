# Architecture

## Two subsystems that share very little

HiDisplay does two unrelated things, and keeping them apart is the main structural decision.

**HiDPI override** is static configuration with system-level risk. It writes a file, needs root, needs
backup and rollback, and its failure mode is a black screen at next login. It is pure data
transformation plus a careful installer.

**Brightness control** is runtime I/O. It needs concurrency control, timeouts, per-display
serialisation and reconnect handling. Its failure mode is a slider that does nothing.

They share exactly four things: display identity, the profile store, diagnostics, and the menu bar.
Nothing else. A HiDPI installer failure must not affect brightness, and a DDC timeout must not block the
UI or the recovery path.

```
┌──────────────────────────────────────────────┐
│ Sources/HiDisplay  (executable)              │
│ MenuBarExtra, Settings, HiDPI tab, AppModel  │
└──────────────────────┬───────────────────────┘
                       │
┌──────────────────────▼───────────────────────┐
│ Sources/HiDisplayKit/Core                    │
│ Models · Discovery · Identity · Diagnostics  │
│ CoreGraphics + IORegistry (public APIs)      │
└───────────────┬──────────────────┬───────────┘
                │                  │
┌───────────────▼──────────┐ ┌─────▼────────────────┐
│ HiDPI/                   │ │ Brightness/          │
│ EDID · Generator ·       │ │ DDC · Native ·       │
│ Validator · Installer    │ │ Gamma · Shade        │
│ (no I/O in Generator)    │ │ (actor-serialised)   │
└──────────────────────────┘ └─────┬────────────────┘
                                   │
                        ┌──────────▼───────────┐
                        │ PlatformShims/       │
                        │ dlsym, degradable    │
                        └──────────────────────┘
```

## Layer rules

- The UI never writes a system file and never calls IOKit directly.
- `HiDPI/Generator` performs no filesystem access, no shell execution, no privileged operation. It is a
  pure function from resolutions to bytes, which is why it is fully testable offline.
- `HiDPI/Installer` takes its filesystem root by injection with **no default**, so a test cannot
  accidentally target `/Library/Displays` and production has to name the real root explicitly.
- All private-API access is confined to `PlatformShims`, resolved with `dlsym`, with a degrade path.
- Everything that touches hardware has a fake: `FakeDDCTransport` lives in the library, not the test
  target, so the whole brightness stack can run with no monitor attached.

## Build

SwiftPM is the source of truth; there is no committed `.xcodeproj`. `swift build` and `swift test` work
from CLI and CI without Xcode project state, `Package.swift` opens directly in Xcode with full IDE
support, and there is no merge-conflict-prone `.pbxproj` carrying information the manifest already has.
`build-app.sh` assembles the `.app` bundle.

## Display identity

The hard problem, and the one the original plan under-estimated.

`CGDirectDisplayID` is reassigned across reconnects and reboots, so it can never be a profile key. The
obvious replacement — `vendor-product-serial` — fails too, because `CGDisplaySerialNumber()` returns `0`
for many external displays on Apple Silicon. Two identical monitors then collapse onto one key and fight
over every setting.

`DisplayIdentityResolver` therefore emits a key plus a **tier**, and persists the tier:

| Tier | Key shape | When | Cost |
| --- | --- | --- | --- |
| `strong` | `v10ac-pd0a1-s0000abcd` or `…-e<edid hash>` | a serial or EDID hash exists | none — survives reboots and port changes |
| `weak` | `v10ac-pd0a1` | no discriminator, but only one such display attached | cannot distinguish a second identical monitor if one appears |
| `location` | `v10ac-pd0a1-l0000000000004001` | no discriminator and ≥2 identical displays attached | breaks when the user changes port, hub or KVM |

A user can pin an identity permanently (`user-<uuid>`), which outranks every tier — a human is a better
authority than the heuristic.

Pairing CoreGraphics displays to IORegistry records is reported honestly as `confident`, `ambiguous` or
`unmatched`. When two records are indistinguishable, one is assigned deterministically so the displays
still get *different* keys, but **both** are marked ambiguous — including the second, which would
otherwise look confident merely because it inherited the first coin flip. The menu surfaces this with a
"This is a separate display" action.

## One metadata backend, behind a protocol that could hold more

Apple Silicon exposes displays through DCP nodes carrying a `DisplayAttributes` dictionary.
`AppleSiliconDisplayMetadataBackend` reads it, and `CompositeDisplayMetadataBackend` tries backends in
order and takes the first non-empty result.

There used to be a second backend reading `IODisplayConnect` with a raw `IODisplayEDID`, the Intel-era
path. It went when the project narrowed to Apple Silicon — that node has no matching services for
external displays there, so it was dead weight that still had to be maintained and tested.

The protocol and the composite stay. They are the seam the tests inject fixture dictionaries through,
and selection is still by which backend returns records rather than `#if arch(arm64)` — so if a future
macOS moves external displays to another branch, that is a new backend rather than a rewrite.

Neither backend needs a private symbol — both are ordinary IORegistry property reads.

One wrinkle that only hardware revealed: on macOS 26 the metadata is on `AppleCLCD2`, while the DDC
channel must be opened from `DCPAVServiceProxy`, and no property joins them. They are joined by the
display unit token in their ancestors' names (`dispext0`), which `IORegistryAccess.displayUnitToken`
extracts. Getting this wrong is silent — `IOAVServiceCreateWithService` simply returns null — so it
presented as a hardware limitation rather than a bug.

## Two signals out of discovery

`DisplayDiscoveryService` publishes two things deliberately:

- `displays` — fast (350 ms debounce). The menu must never show a monitor that is already gone.
- `settled` — slow (2 s). Brightness restoration waits on this, because a display frequently appears in
  `CGGetOnlineDisplayList` before its DDC bus will answer. Restoring on the fast signal produces
  timeouts and, on some monitors, a retry storm.

Both timers reset on every reconfiguration callback, so unplugging a dock with three monitors produces
exactly one settle event.

## Brightness pipeline

```
ddc  →  gamma  →  shade          (external displays only)
```

Real backlight before faked, and gamma before shade because gamma does not appear in screenshots.

**The built-in panel is not in this pipeline at all.** `BrightnessControllerResolver.resolve` returns no
controller for it, before any priority table or user override is consulted, and `BrightnessCoordinator`
does not even probe it. macOS owns that value through the brightness keys, Control Center and
ambient-light adaptation; a second owner can only fight them, and it is the one screen a user cannot
unplug to escape a bad state. The rule lives in the resolver rather than the UI so that no path — a
saved override from an older version, Sync Displays, a brightness key — can route a write to it.
`NativeBrightnessController` stays for `hidisplay-probe`, which still reports what DisplayServices would
do; nothing in the app selects it.

Concurrency guarantees, each a requirement rather than an optimisation:

- **One `DDCCommandQueue` actor per display**, keyed by stable key. A reconnect cannot route one
  monitor's commands into another's queue.
- **No concurrent I2C to one display.** A single drain loop means one frame on the wire at a time;
  overlapping writes are how monitors get wedged until power-cycled.
- **Coalescing that never drops the final value.** The drain loop re-checks for a newer pending value
  *after* each write completes, so the position the user released on is always the last frame sent.
- **Bounded retries, only on transient errors.** `.unsupported` is never retried.
- **Connection epochs.** Async work is stamped; a probe or restore belonging to a previous connection is
  discarded rather than written into the new one.
- `setBrightness` returns without waiting for the wire, so a 300 ms monitor does not make the slider
  stutter. Asserted by `testSlowTransportDoesNotBlockTheCaller`.

`resetAllDimming()` clears gamma and shade but deliberately leaves native and DDC alone: those are the
display's real settings, and an emergency reset that also blasted the backlight to full would be a
surprise rather than a rescue. What it fixes is the state the user cannot otherwise escape.

## The app layer

Everything in `Sources/HiDisplay/` is glue and policy; nothing there is testable without a window server,
which is exactly why nothing there is allowed to hold logic worth testing.

- `AppModel` owns the ordering rules — probe after settle, persist after change, restore after probe —
  so no view re-derives them. It re-publishes `BrightnessCoordinator.objectWillChange`, because SwiftUI
  does not propagate changes through a nested `ObservableObject` and the asynchronous half of the UI is
  otherwise silently dead.
- `BrightnessKeyTap` is a `CGEventTap` on system-defined events. Its one hard rule: an event that
  concerns the built-in panel is returned unmodified, so macOS keeps driving that panel and drawing its
  HUD. Only a press affecting external displays alone is consumed. A tap disabled by timeout is
  re-enabled from the callback — without that the keys stop working until relaunch, silently.
- `PrivilegedInstaller` is split from the plan on purpose. `AppModel.planInstall` computes what would
  change and writes nothing; `performInstall` is the only path that can raise an authorization prompt,
  and it runs after the user has seen the plan. What the plan reports as discarded — foreign entries, a
  patched EDID — has to reach the UI, since after the write it is only recoverable from the backup.
- `LoginItem` treats `.requiresApproval` as a state to explain, not an error: registration succeeding
  while the switch is off in System Settings is normal, not a failure.

## Diagnostics

`DiagnosticsReport` carries what support needs and nothing that identifies the user: no username, no home
path, no raw serial, no raw EDID. Serials appear only as the truncated hash already used for the profile
key. `testReportContainsNoSerialNumberOrHomePath` asserts this rather than trusting it, because these
files get pasted into public issue trackers.

The most useful field is the private-API shim status — it is the difference between "brightness does
nothing" and "brightness does nothing *because* this macOS removed a symbol".
