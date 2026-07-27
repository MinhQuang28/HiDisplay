# Recovery

What to do when a display override leaves the Mac in a bad state. Written to be usable when HiDisplay
itself will not run.

## What can go wrong

A display override changes a file macOS parses when the window server starts. Realistic failures:

- Black screen after logging in or after wake.
- The monitor loses its previous refresh rate, or HDR stops being offered.
- The chosen resolution simply never appears (harmless — the override was ignored).
- A monitor whose firmware handles unusual timings badly shows artefacts.

Only the first is genuinely disruptive, and it is recoverable in every case, because the override is one
file in a known location and nothing else on the system was touched.

## Before installing

The app creates a recovery package **before** anything is written:

```
~/Downloads/HiDisplay-Recovery-YYYYMMDD-HHMMSS/
├── README.txt          plain-language instructions, both routes
├── restore.command     double-clickable undo
├── manifest.json       paths, SHA-256 hashes, display identity, app version
├── backup/             the previous file, if there was one
└── install/            the override file, named exactly as it must be on disk
```

Keep it until the override has survived a logout and a sleep/wake cycle.

## Route 1 — the Mac boots normally

Double-click `restore.command`, enter your password, log out and back in (a restart is not required).

The script verifies the backup's SHA-256 against the manifest before restoring it, checks the target is
inside `/Library/Displays/Contents/Resources/Overrides`, refuses to touch `/System`, and never deletes a
directory recursively.

## Route 2 — the screen is unusable

The override only takes effect at login, so a Mac with a bad override still boots — it is the window
server that fails. Use Recovery.

**Apple Silicon:**

1. Shut down. Hold the power button until *Loading startup options* appears.
2. Choose **Options → Continue** to enter macOS Recovery.
3. **Utilities → Terminal**.

**Intel:** hold ⌘R at power-on, then Utilities → Terminal.

In the Terminal, the normal disk is mounted under `/Volumes`. Find its name:

```sh
ls /Volumes
```

Then, replacing `Macintosh HD` with your disk's name:

```sh
# If HiDisplay added a new file — delete it:
rm "/Volumes/Macintosh HD/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-YYYY"

# If it replaced an existing file — put the original back from the recovery package:
cp "/Volumes/Macintosh HD/Users/<you>/Downloads/HiDisplay-Recovery-.../backup/DisplayVendorID-XXXX/DisplayProductID-YYYY" \
   "/Volumes/Macintosh HD/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-YYYY"
```

The exact paths are in `README.txt` and `manifest.json` inside the package — you do not have to work out
the hex IDs yourself.

Restart.

### If the recovery package is gone

Every override HiDisplay installs is one file under
`/Library/Displays/Contents/Resources/Overrides`. Removing the whole vendor directory for the affected
display returns macOS to its built-in behaviour:

```sh
ls "/Volumes/Macintosh HD/Library/Displays/Contents/Resources/Overrides"
rm "/Volumes/Macintosh HD/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-YYYY"
```

Nothing under `/Library/Displays` is required for macOS to boot. Note that other tools may have installed
overrides there too — delete only the file for the display you changed.

**Never touch `/System/Library/Displays/`.** HiDisplay never writes there; those are Apple's own files and
they are SIP-protected.

## Software dimming left the screen dark

Not a recovery-mode situation.

- **Gamma dimming** is reverted by CoreGraphics when the process exits, so quitting HiDisplay restores it.
  Force-quitting works too.
- **A shade overlay** sits below the menu bar level specifically so you can always reach the menu bar and
  choose **Reset Dimming**.
- **Reset Dimming** in the menu clears all gamma and shade dimming immediately. It deliberately does not
  touch the monitor's own backlight, since that is the display's real setting.

If the app is unresponsive, quitting it removes every overlay.

## Brightness stopped working after a macOS update

Likely a private symbol was removed. Open **Settings → Diagnostics**: the *Private API status* section
shows whether `IOAVService` and `DisplayServices` resolved, and the reason if not. Export the diagnostics
report and include it in a bug report — it contains no personal data.

The app is built to degrade rather than break here: brightness falls back to gamma or shade dimming.

## Removing HiDisplay entirely

1. Menu → **Reset Dimming**, then quit.
2. Undo any installed override via `restore.command`, or delete the file as above.
3. Delete `~/Library/Application Support/HiDisplay/`.
4. Delete the app.

An override left behind after deleting the app is harmless but permanent — macOS keeps applying it. Undo
it before uninstalling.
