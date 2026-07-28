#!/bin/bash
# Build HiDisplay and assemble a runnable menu-bar .app bundle (locally signed).
set -euo pipefail

cd "$(dirname "$0")"

# Use regular Xcode, fall back to Xcode-beta if needed. DEVELOPER_DIR is set rather than relying on
# xcode-select, so the build works without `sudo xcode-select -s` having been run.
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
    export DEVELOPER_DIR="${DEVELOPER_DIR:-.}"
fi

if [ -f "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]; then
    SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
else
    SWIFT="$(which swift)" || { echo "Error: swift not found in PATH or Xcode"; exit 1; }
fi

APP_NAME="HiDisplay"
BUNDLE_ID="com.hidisplay.app"
VERSION="0.6.0"
MIN_MACOS="13.0"
OUT="build/${APP_NAME}.app"

echo "==> swift build -c release"
"$SWIFT" build -c release
BIN="$("$SWIFT" build -c release --show-bin-path)/${APP_NAME}"

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>LSUIElement</key><true/>
    <!-- Required, not optional: "Restart Now" after installing an override talks to System Events,
         and since macOS 10.14 an app with no usage string is denied Apple Events silently — the
         button would appear to do nothing. The privileged install itself does not need this; it runs
         its shell script in-process. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>HiDisplay asks System Events to restart your Mac, so a newly installed display override takes effect. Nothing else is automated.</string>
    <key>NSHumanReadableCopyright</key><string>HiDisplay</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity if present (run tools/setup-signing-cert.sh once).
# A fixed cert keeps the designated requirement constant across rebuilds. HiDisplay needs no
# Accessibility permission today, but the same reasoning will apply to the privileged helper: an
# ad-hoc signature changes the cdhash every build, which makes SMAppService treat each rebuild as a
# different program. Fall back to ad-hoc if the cert isn't set up.
SIGN_HASH="$(security find-identity "$HOME/Library/Keychains/login.keychain-db" \
    | awk '/HiDisplay Local Signing/ {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
    echo "==> signing with stable identity ($SIGN_HASH)"
    codesign --force --sign "$SIGN_HASH" --timestamp=none "$OUT" >/dev/null 2>&1
else
    echo "==> ad-hoc signing (run tools/setup-signing-cert.sh for a stable signature)"
    codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1
fi

echo "==> done: $(cd "$(dirname "$OUT")" && pwd)/${APP_NAME}.app"
echo
echo "Install it before running:  rm -rf /Applications/${APP_NAME}.app && cp -R \"$OUT\" /Applications/"
echo "Launching from build/ registers a second LaunchServices record for the same bundle ID, which"
echo "makes SMAppService unable to resolve the login item (status .notFound)."
