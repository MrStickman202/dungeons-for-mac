#!/bin/bash
# App entry point.
# 1. Checks GitHub for a newer version of the app's scripts (verified by SHA-256).
# 2. Uses whichever is newer: the scripts bundled in the app, or the downloaded ones.
# 3. Compiles the app window (an AppleScript applet) on this Mac when it changes, and opens it.

RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
AS="$HOME/Library/Application Support/DungeonsForMac"
APPDIR="$AS/app"
UPD="$AS/app-update"
UIAPP="$APPDIR/Dungeons for Mac.app"
LOG="$AS/logs/launcher.log"
UPDATE_BASE="$(cat "$RES/update-url" 2>/dev/null)"
[ -n "$UPDATE_BASE" ] || UPDATE_BASE="https://github.com/MrStickman202/dungeons-for-mac/releases/download/app-latest"

mkdir -p "$APPDIR" "$UPD" "$AS/logs"

alert() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display dialog (item 1 of argv) buttons {"OK"} default button "OK" with title "Dungeons for Mac" with icon stop' \
    -e 'end run' "$1" >/dev/null 2>&1
}

build_of() { # DFM_BUILD=<n> in a core.sh, 0 if none
  local b
  b=$(sed -n 's/^DFM_BUILD=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)
  echo "${b:-0}"
}

# --- 1. update check (quick; skipped silently when offline) ------------------
want=$(/usr/bin/curl -fsSL --max-time 6 "$UPDATE_BASE/app.tar.gz.sha256" 2>/dev/null | awk '{print $1}')
have=$(cat "$UPD/.sha" 2>/dev/null)
case "$want" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    if [ "$want" != "$have" ]; then
      tmp=$(mktemp -d "$AS/upd.XXXXXX")
      if /usr/bin/curl -fsSL --max-time 120 -o "$tmp/app.tar.gz" "$UPDATE_BASE/app.tar.gz" \
         && [ "$(/usr/bin/shasum -a 256 "$tmp/app.tar.gz" | awk '{print $1}')" = "$want" ] \
         && /usr/bin/tar -xzf "$tmp/app.tar.gz" -C "$tmp" \
         && [ -f "$tmp/app/core.sh" ] && [ -f "$tmp/app/ui.applescript" ]; then
        rm -rf "$UPD.new"; mv "$tmp/app" "$UPD.new" && rm -rf "$UPD" && mv "$UPD.new" "$UPD"
        echo "$want" > "$UPD/.sha"
        echo "$(date) updated app scripts to $want" >> "$LOG"
      else
        echo "$(date) app update download failed" >> "$LOG"
      fi
      rm -rf "$tmp"
    fi ;;
esac

# --- 2. pick the newer set of scripts -----------------------------------------
SRC="$RES"
if [ -f "$UPD/core.sh" ] && [ "$(build_of "$UPD/core.sh")" -gt "$(build_of "$RES/core.sh")" ]; then
  SRC="$UPD"
fi
# a newer launcher replaces this one for next time (the bundle is the user's own)
if [ "$SRC" = "$UPD" ] && [ -f "$UPD/launcher.sh" ] && ! cmp -s "$UPD/launcher.sh" "$0"; then
  cp -f "$UPD/launcher.sh" "$0.new" 2>/dev/null && chmod 755 "$0.new" && mv -f "$0.new" "$0" 2>/dev/null
fi

for f in core.sh ui.applescript AppIcon.icns; do
  [ -f "$SRC/$f" ] || continue
  if ! cmp -s "$SRC/$f" "$APPDIR/$f"; then
    cp -f "$SRC/$f" "$APPDIR/$f" || { alert "Couldn't copy $f into Application Support."; exit 1; }
  fi
done
chmod 755 "$APPDIR/core.sh"
/usr/bin/xattr -d com.apple.quarantine "$APPDIR/core.sh" "$APPDIR/ui.applescript" 2>/dev/null

# --- 3. build the window applet when it's missing or changed ----------------
if [ ! -d "$UIAPP" ] || ! cmp -s "$APPDIR/ui.applescript" "$APPDIR/.ui-built-from"; then
  rm -rf "$UIAPP"
  if ! OUT=$(/usr/bin/osacompile -o "$UIAPP" "$APPDIR/ui.applescript" 2>&1); then
    echo "$(date) osacompile failed: $OUT" >> "$LOG"
    # a broken update must not lock the user out: fall back to the bundled window
    if [ "$SRC" = "$UPD" ] && cp -f "$RES/ui.applescript" "$APPDIR/ui.applescript" \
       && OUT2=$(/usr/bin/osacompile -o "$UIAPP" "$APPDIR/ui.applescript" 2>&1); then
      cp -f "$RES/core.sh" "$APPDIR/core.sh"
    else
      alert "Couldn't build the Dungeons for Mac window:

$OUT"
      exit 1
    fi
  fi
  cp -f "$APPDIR/AppIcon.icns" "$UIAPP/Contents/Resources/applet.icns" 2>/dev/null
  PL="$UIAPP/Contents/Info.plist"
  {
    /usr/bin/plutil -replace CFBundleIdentifier -string "com.softsignal.dungeonsformac.window" "$PL"
    /usr/bin/plutil -replace CFBundleName -string "Dungeons for Mac" "$PL"
    /usr/bin/plutil -replace CFBundleDisplayName -string "Dungeons for Mac" "$PL"
  } >> "$LOG" 2>&1
  chmod a-w "$UIAPP/Contents/Resources/Scripts/main.scpt" 2>/dev/null
  /usr/bin/codesign --force --deep --sign - "$UIAPP" >> "$LOG" 2>&1
  /usr/bin/xattr -dr com.apple.quarantine "$UIAPP" 2>/dev/null
  cp -f "$APPDIR/ui.applescript" "$APPDIR/.ui-built-from"
  touch "$UIAPP"
fi

exec /usr/bin/open "$UIAPP"
