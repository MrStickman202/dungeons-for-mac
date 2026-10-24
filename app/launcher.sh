#!/bin/bash
# Dungeons for Mac - app entry point.
# Copies the engine script into Application Support, compiles the app window
# (an AppleScript applet) on this Mac the first time, then opens it.

RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
AS="$HOME/Library/Application Support/DungeonsForMac"
APPDIR="$AS/app"
UIAPP="$APPDIR/Dungeons for Mac.app"
LOG="$AS/logs/launcher.log"

mkdir -p "$APPDIR" "$AS/logs"

alert() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display dialog (item 1 of argv) buttons {"OK"} default button "OK" with title "Dungeons for Mac" with icon stop' \
    -e 'end run' "$1" >/dev/null 2>&1
}

# Keep the working copies in sync with this app's version
for f in core.sh ui.applescript AppIcon.icns; do
  if ! cmp -s "$RES/$f" "$APPDIR/$f"; then
    cp -f "$RES/$f" "$APPDIR/$f" || { alert "Couldn't copy $f into Application Support."; exit 1; }
  fi
done
chmod 755 "$APPDIR/core.sh"
/usr/bin/xattr -d com.apple.quarantine "$APPDIR/core.sh" "$APPDIR/ui.applescript" 2>/dev/null

# Build the window applet when it's missing or this version changed it
if [ ! -d "$UIAPP" ] || ! cmp -s "$APPDIR/ui.applescript" "$APPDIR/.ui-built-from"; then
  rm -rf "$UIAPP"
  if ! OUT=$(/usr/bin/osacompile -o "$UIAPP" "$APPDIR/ui.applescript" 2>&1); then
    echo "$(date) osacompile failed: $OUT" >> "$LOG"
    alert "Couldn't build the Dungeons for Mac window:

$OUT"
    exit 1
  fi
  cp -f "$APPDIR/AppIcon.icns" "$UIAPP/Contents/Resources/applet.icns"
  PL="$UIAPP/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string "com.softsignal.dungeonsformac.window" "$PL" >> "$LOG" 2>&1
  /usr/bin/plutil -replace CFBundleName -string "Dungeons for Mac" "$PL" >> "$LOG" 2>&1
  /usr/bin/plutil -replace CFBundleDisplayName -string "Dungeons for Mac" "$PL" >> "$LOG" 2>&1
  # The applet must never rewrite its own script (that breaks its signature)
  chmod a-w "$UIAPP/Contents/Resources/Scripts/main.scpt" 2>/dev/null
  /usr/bin/codesign --force --deep --sign - "$UIAPP" >> "$LOG" 2>&1
  /usr/bin/xattr -dr com.apple.quarantine "$UIAPP" 2>/dev/null
  cp -f "$APPDIR/ui.applescript" "$APPDIR/.ui-built-from"
  touch "$UIAPP"
fi

exec /usr/bin/open "$UIAPP"
