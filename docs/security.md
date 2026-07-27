# Security

## Threat model

The app writes a file that macOS parses at login, as root. Two things must be impossible: writing outside
the one allowlisted directory, and being tricked into destroying a file it did not create.

## What is enforced today

### Path handling

`OverridePaths.resolve` is the only way a target path is produced. It rejects, in order:

- an absolute path,
- an empty path,
- any path containing `..`,
- a **symlink anywhere along the path** — refused rather than followed, because following one is exactly
  how a root-privileged write lands outside the allowlisted root,
- a resolved path that does not sit under the root (checked on the *resolved* path, not the joined
  string, so `a/../../b` cannot escape),
- anything under `/System/Library/Displays/…`, unconditionally.

`OverridePathTests` covers each case, including a real symlinked vendor directory on disk.

### Writes

- Root injected with **no default**, so tests cannot reach the real path and production must name it.
- Atomic writes only (`Data.write(options: .atomic)`), so an interrupted write cannot leave a
  half-parsed override for WindowServer to read at next login.
- File size bounded to 1 MiB.
- Every existing file backed up before replacement, with its SHA-256 recorded.
- `apply` verifies each payload's hash against the plan **before touching anything**, so the bytes
  written are provably the bytes previewed.
- Rollback on any mid-sequence failure: replaced files restored from backup, created files removed,
  created directories removed only if empty.

### Deletion

`removeAppOwned` hashes the file on disk and compares it to what the manifest says the app wrote. A
mismatch means someone else edited it since, and it refuses — deleting it would be destroying another
tool's work. Only the named file is removed; the vendor directory only if it is left empty; the override
root never.

No code path anywhere runs `rm -rf`, and no path is ever built by interpolating user input into a shell
string.

### Restore

`restore` verifies each backup against the recorded `sha256Before` before putting it back, so a corrupted
or swapped backup is refused rather than installed.

### Recovery script

`restore.command` is generated with `set -euo pipefail`, quoted literal paths taken from the manifest, an
explicit check that the target is inside the override root, an explicit refusal to touch `/System/*`,
SHA-256 verification of the backup before copying it, and `rmdir` (never recursive) for an emptied vendor
directory. `RecoveryPackageTests` asserts these properties on the generated text rather than leaving them
to review.

### Logging and diagnostics

No serial number, EDID blob, username or home path in OSLog or in the diagnostics report. Presence flags
(`hasSerial`, `edidHashPresent`) carry the same debugging value without the identifying data. Asserted by
`DiagnosticsTests.testReportContainsNoSerialNumberOrHomePath`.

### SIP

No feature requires SIP to be disabled, and the app never suggests it. The writable override root makes
that achievable rather than aspirational — see [hidpi-overrides.md](hidpi-overrides.md).

### Private APIs

Confined to `PlatformShims`, resolved via `dlsym` through a single function, each with a degrade path and
an allowlist entry. A macOS release that removes one degrades a feature; it does not crash the app. See
[private-apis.md](private-apis.md).

## Not yet built — Milestone E

The privileged helper. Until it exists, the app writes only inside `~/Downloads` and shows the user the
command to run. The installer layer is complete and tested against a temporary root but is not wired to
the real path.

When it is built:

- **`SMAppService.daemon(plistName:)`**, not `SMJobBless`. The latter is deprecated, and the deployment
  target is macOS 13+ specifically so the modern API is available.
- Helper in `Contents/MacOS/`, launchd plist in `Contents/Library/LaunchDaemons/`, same Team ID as the
  app, signed, app notarized.
- `.requiresApproval` from `register()` is normal on first run and must be presented as a step
  ("System Settings → General → Login Items & Extensions"), not as an error.
- XPC clients verified by **`auditToken` plus a code requirement**, never by PID — a PID can be reused
  between the check and the call.
- The helper accepts three operations only: install override, restore backup, remove app-owned override.
  It never accepts an arbitrary path or an arbitrary command.
- It re-validates everything server-side: path inside the allowlist after canonicalisation, no symlink,
  parses as a plist, plausible vendor/product IDs, size bounded. A helper that trusts its client is not a
  security boundary.
- No resident root daemon: it does its work and exits.

## The privileged install, and the rule it bends

`PrivilegedInstaller` runs a shell string as root through a system authorization prompt. The security
rule elsewhere in this document says never to build a privileged command from user input, and that rule
is kept **literally** rather than being quietly dropped:

- The only variable parts are two paths.
- The destination comes from the display's vendor and product IDs — `UInt32` values formatted as hex,
  which cannot contain a shell metacharacter. `PrivilegedPathSafetyTests` sweeps the ID space and
  asserts this.
- The source is a file the app wrote into its own temporary directory under a generated UUID.
- Both are re-checked against a strict character allowlist immediately before the command is built, and
  the destination is proved by `OverridePaths.resolve` to sit inside the override root. Anything failing
  either check refuses rather than escaping harder.
- The command is three fixed operations — `mkdir -p`, `cp`, `chmod 644`. No expansion, no `rm`, no
  recursion.
- The result is verified afterwards by reading the file back without privileges and comparing SHA-256
  against the plan. An unverified privileged write is a write whose outcome you do not know.
- The recovery package, including the backup of the file being replaced, is created **before** the
  privileged step.

This is the fallback the implementation plan anticipated for builds without notarization (§12.6), not
the end state. The intended design is still a signed helper registered via `SMAppService` with a narrow
XPC contract; that needs a Developer ID this build does not have.

## Release checklist

- [x] No arbitrary shell execution — one fixed command, no user input interpolated (see above)
- [x] No credentials stored
- [x] Symlinks rejected
- [x] Paths canonicalised before the containment check
- [x] Atomic writes
- [x] Backup before replace, with hashes
- [x] Plist validated before write
- [x] File size bounded
- [x] Logs free of sensitive data
- [x] No code path requires SIP disabled
- [x] No writes under `/System/`
- [x] Every `dlsym` symbol in the allowlist, with a degrade path
- [ ] Hardened Runtime
- [ ] Notarization
- [ ] Helper registered via `SMAppService`
- [ ] XPC caller verified by `auditToken` + code requirement
