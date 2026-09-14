# Changelog

Newest first. Versions are the value of `AppModel.version`; tags are `v<version>`.

## 0.7.0 — 2026-09-14

Breaking: minimum macOS is now 14 (Sonoma). Profile schema 2 migrates automatically on first launch.

### Fixed
- **Serial numbers no longer appear in logs or diagnostics.** A serial-identified display's profile key
  carried the raw serial (`-s%08x`); it now carries a truncated SHA-256 of it. Existing profiles, HiDPI
  profiles and pinned identities are re-keyed on load, so saved brightness and overrides survive.
- **Stale gamma ramps after a disconnect.** The gamma controller kept factors for departed displays and
  re-applied them on the next reconfiguration; CoreGraphics reuses display IDs, so the next monitor in
  that slot inherited the dim, and a replug that then bound DDC kept the ramp underneath. Departed
  displays are now pruned on settle.
- **DDC I/O no longer blocks the cooperative thread pool.** `IOAVServiceReadI2C`/`WriteI2C` are
  synchronous and uncancellable; they now run on a private serial queue per display. The bus token was
  already held for the whole call (verified, and now asserted by a test) — the earlier concern that a
  timeout released it mid-transaction was unfounded.
- **Clean quit flushes profiles properly.** `applicationShouldTerminate` returns `.terminateLater` and
  awaits the flush instead of blocking the main thread on a semaphore.
- **Downloads folder access explains itself.** `NSDownloadsFolderUsageDescription` added; a TCC denial
  no longer looks like a generic install failure.
- **Privileged install script hardened.** Absolute binary paths, backslash escaping in the AppleScript
  wrapper, and a refusal to write when an already-existing override root is not owned by the user the
  script runs as (`/Library` is admin-writable).

### Changed
- **Brightness HUD redesigned** for macOS 26/27: a Liquid Glass capsule under the menu bar towards the
  top-right of the display (10% right margin), glyph plus a continuous level bar, instead of the pre-26
  200-point square. macOS 14/15 keep the dark HUD material in the same capsule.
- Swift 6 language mode on every target; strict concurrency is now a compile error.
- Deployment target macOS 14: `AvailabilityCompat.swift` removed, Settings opens via `openSettings`.
- The Accessibility permission poll is a cancellable task instead of a `Timer`.
- `CFBundleVersion` is `<version>.<commit count>`, so LaunchServices can tell rebuilds apart.
- CI pins the Xcode toolchain, uploads the bundle, and a `v*` tag publishes a release with a `.sha256`
  asset. `package-release.sh` no longer swallows `gh release create` errors and refuses a dirty tree.

### Docs
- DDC status corrected: verified on a ViewSonic VX2780-2K. Test count 278. Security notes updated to
  describe the real install script.

## 0.6.5 — 2026-08-26
- No bright flash at cold boot: known-DDC displays are held instead of downgraded.

## 0.6.4 — 2026-08-18
- No dimming flash on wake; saved brightness re-asserted. Faster settle, remembered DDC quirks,
  off-main discovery.

## 0.6.3 — 2026-08-13
- DDC recovers after monitor sleep/wake.

Earlier history: `git log` — 0.6.0 (DDC works, installer stops destroying overrides), 0.5.0 (Apple
Silicon only), 0.4.0 (HiDPI overrides and external-display brightness).
