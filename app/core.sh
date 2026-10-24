#!/bin/bash
# Dungeons for Mac - core engine
#
# Sets up a tuned Windows layer (Wine 11 from the CrossOver 26.3 tree + DXMT,
# Direct3D 11 -> Metal) and runs the Launcher (Win32) version of Minecraft
# Dungeons on Apple silicon Macs. Called by the app's window; every command
# prints a short machine-readable answer and exits 0 unless the command is
# unknown.
#
# Written for macOS's /bin/bash 3.2: no associative arrays, no mapfile,
# no ${var,,}, no set -u.

DFM_VERSION="1.0.0"

SELF="$0"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac

AS="${DFM_HOME:-$HOME/Library/Application Support/DungeonsForMac}"
ENG="$AS/engine"
FW="$ENG/frameworks"
PREFIX="$AS/prefix"
DL="$AS/downloads"
STATE="$AS/state"
LOGS="$AS/logs"
CONF="$AS/settings.conf"
WINE="${DFM_TEST_WINE:-$ENG/engine/bin/wine}"
WINESERVER="${DFM_TEST_WINESERVER:-$ENG/engine/bin/wineserver}"
READY_MARK="$ENG/.dfm-ready"
PREFIX_MARK="$PREFIX/.dfm-prefix-ok"
VCRUN_MARK="$PREFIX/.dfm-vcrun-ok"
GAME_DIR="$PREFIX/drive_c/Games/Minecraft Dungeons"
MCL_EXE="$PREFIX/drive_c/Program Files (x86)/Minecraft Launcher/MinecraftLauncher.exe"
SHIPPING_EXE="Dungeons-Win64-Shipping.exe"
# Lower-case on purpose: `find -iname` matches either way, and a running find
# can't be mistaken for the game by the case-sensitive `pgrep -f` below.
SHIPPING_FIND="dungeons-win64-shipping.exe"

# ---------------------------------------------------------------------------
# Pinned components. Same builds, URLs and SHA-256 sums as Highball's verified
# engine manifest x64-crossover26.3-r29 (github.com/gauthierpiarrette/highball),
# minus D3DMetal (it draws Dungeons' 3D world black) and the 32-bit extras.
# ---------------------------------------------------------------------------
ENGINE_ID="x64-crossover26.3-r29+dxmt-a444716"

WINE_URL="https://github.com/gauthierpiarrette/highball-engine/releases/download/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer.tar.gz"
WINE_SHA="1d1a130c0108a4bbb88cd289c3c313292868c3b84010eb315801eba43026e3e8"
WINE_SIZE=334884359

RT_URL="https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
RT_SHA="9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a"
RT_SIZE=84533420
RT_SUBPATH="Template-1.0.11.app/Contents/Frameworks"

DXMT_URL="https://github.com/gauthierpiarrette/highball-engine/releases/download/dxmt-highball-20260930T161516Z-a444716/dxmt-highball-20260930T161516Z-a444716.tar.gz"
DXMT_SHA="96feaf5d98d3c6cdc3edea9503e2891d435df8d5bfdf7d3f6998a56ec62bbd58"
DXMT_SIZE=18923969

MVK_URL="https://github.com/gauthierpiarrette/highball/releases/download/engine-components/moltenvk-1.4.2-shadow-import-1-linear-fallback-1-shadow-readback-1-x86_64.tar.gz"
MVK_SHA="7c84c592c023e761994cf4a0f5fb2e0a8a22bac8dfe3f787c4135a735f873e90"
MVK_SIZE=1733593

ABUF_URL="https://github.com/gauthierpiarrette/highball-engine/releases/download/audiobuf-20261008/audiobuf-20261008.tar.xz"
ABUF_SHA="8b84fa43f7394a3865eef99f4afc97875f155872930cc9f69438ee4a918f17e5"
ABUF_SIZE=5700

# Microsoft's Visual C++ 2015-2022 runtimes (pinned build, Highball's vcrun2022 recipe)
VC64_URL="https://aka.ms/vs/17/release/14.44.35211/VC_redist.x64.exe"
VC64_SHA="${DFM_TEST_VC64_SHA:-cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b}"
VC86_URL="https://aka.ms/vs/17/release/14.44.35211/VC_redist.x86.exe"
VC86_SHA="${DFM_TEST_VC86_SHA:-0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64}"

# Mojang's Windows 7/8 launcher (experimental path; Mojang doesn't publish a checksum)
MCL_URL="https://launcher.mojang.com/download/MinecraftInstaller.msi"

# ---------------------------------------------------------------------------
# Microsoft Store (MSIXVC) path: Xodus client + the Dungeons for Mac engine,
# both built by github.com/MrStickman202/dungeons-for-mac. The engine is Wine
# from CrossOver 26.3 with Highball's, Xodus's and Ferestre's patches and
# xgameruntime (the Xbox game runtime). Checksums come with each release.
# ---------------------------------------------------------------------------
DFM_BUILDS="${DFM_BUILDS:-https://github.com/MrStickman202/dungeons-for-mac/releases/download/latest-build}"
STORE_PRODUCT="9P8MK4NC0LJB"          # Minecraft Dungeons for Windows (Microsoft.Lovika)
CLIENT_DIR="$AS/client"
XCLI="$CLIENT_DIR/xodus-cli"
XSVC="$CLIENT_DIR/xodus-service"
STORE_DIR="$AS/games/minecraft-dungeons-store"
STORE_ENGINE_MARK="$ENG/.dfm-store-engine"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
mkdirs() { mkdir -p "$AS" "$DL" "$STATE" "$LOGS" 2>/dev/null; }

log() {
  mkdirs
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGS/dfm.log"
}

# One-line, pipe-free text for the window's parser
clean() { printf '%s' "$*" | tr '|\n\r\t' '/   '; }

progress() { # percent (-1 = unknown) message
  local tmp="$STATE/progress.$$"
  printf 'run|%s|%s\n' "$1" "$(clean "$2")" > "$tmp" && mv -f "$tmp" "$STATE/progress"
}

fail() { clean "$*" > "$STATE/errmsg"; log "ERROR: $*"; return 1; }
okmsg() { clean "$*" > "$STATE/okmsg"; }

fsize() { # bytes in a file, 0 if missing
  local s
  s=$(stat -c %s "$1" 2>/dev/null) || s=$(stat -f %z "$1" 2>/dev/null) || s=0
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  printf '%s' "$s"
}

devid() { # filesystem device of a path
  stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null || echo "?"
}

sha_ok() { [ "$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')" = "$2" ]; }

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}'; }

fmt_time() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

is_mac() { [ "$(uname -s)" = Darwin ]; }

reveal() { # open a file or folder in Finder / default app
  if is_mac; then open "$@" >/dev/null 2>&1; else echo "open $*" >> "$LOGS/dfm.log"; fi
}

copy_tree() { # src dest  (ditto keeps macOS metadata; cp -R elsewhere)
  if command -v ditto >/dev/null 2>&1; then ditto "$1" "$2"; else cp -R "$1" "$2"; fi
}

# ---------------------------------------------------------------------------
# Settings (key=value lines)
# ---------------------------------------------------------------------------
conf_get() { # key default
  local v=""
  [ -f "$CONF" ] && v=$(grep -E "^$1=" "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

conf_set() { # key value
  mkdirs
  local tmp="$CONF.tmp.$$"
  { [ -f "$CONF" ] && grep -vE "^$1=" "$CONF"
    printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\n\r')"
  } > "$tmp" && mv -f "$tmp" "$CONF"
}

conf_unset() {
  [ -f "$CONF" ] || return 0
  local tmp="$CONF.tmp.$$"
  grep -vE "^$1=" "$CONF" > "$tmp"; mv -f "$tmp" "$CONF"
}

# ---------------------------------------------------------------------------
# Wine environment
# ---------------------------------------------------------------------------
# DYLD_* variables are stripped whenever a SIP-protected program (nohup, env,
# arch...) sits between here and Wine, so Wine is always started straight
# from this shell.
wine_env() { # setup | game | launcher
  export WINEPREFIX="$PREFIX"
  export PATH="$ENG/engine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export DYLD_FALLBACK_LIBRARY_PATH="$FW:$FW/GStreamer.framework/Versions/1.0/lib"
  export DYLD_FALLBACK_FRAMEWORK_PATH="$FW"
  export GST_PLUGIN_PATH="$FW/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"
  export WINEDEBUG="fixme-all"
  export CX_FWD_COMPAT_GL_CTX=1
  # Lets browser-based windows (Microsoft sign-in, launchers) draw on this Wine
  export DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1
  # No Windows shortcuts on the Mac desktop
  export WINEDLLOVERRIDES="winemenubuilder.exe=d"
  unset WINEDLLPATH_PREPEND DXMT_CONFIG DXMT_METALFX_SPATIAL_SWAPCHAIN MTL_HUD_ENABLED
  unset DXVK_ASYNC DXVK_FRAME_RATE DYLD_INSERT_LIBRARIES
  ulimit -n 10240 2>/dev/null

  case "$1" in
    game)
      case "$(conf_get sync msync)" in
        esync) export WINEESYNC=1 WINEMSYNC=0 ;;
        off)   export WINEESYNC=0 WINEMSYNC=0 ;;
        *)     export WINEMSYNC=1 WINEESYNC=0 ;;
      esac
      local fps; fps=$(conf_get fps 60)
      case "$(conf_get renderer dxmt)" in
        dxvk)
          export WINEDLLPATH_PREPEND="$FW/renderer/dxvk/wine"
          export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;dxgi,d3d9,d3d10core,d3d11=n,b"
          export DXVK_ASYNC=1
          [ "$fps" != 0 ] && export DXVK_FRAME_RATE="$fps"
          ;;
        wined3d)
          ;;
        *)
          export WINEDLLPATH_PREPEND="$ENG/renderers/dxmt/wine"
          local cfg=""
          [ "$fps" != 0 ] && cfg="d3d11.preferredMaxFrameRate=$fps;"
          if [ "$(conf_get sharp 0)" = 1 ]; then
            export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
            cfg="${cfg}d3d11.metalSpatialUpscaleFactor=2;"
          fi
          [ -n "$cfg" ] && export DXMT_CONFIG="$cfg"
          ;;
      esac
      [ "$(conf_get hud 0)" = 1 ] && export MTL_HUD_ENABLED=1
      [ -f "$FW/libhbaudiobuf.dylib" ] && export DYLD_INSERT_LIBRARIES="$FW/libhbaudiobuf.dylib"
      ;;
    launcher)
      # Chromium-based launchers are happiest without msync
      export WINEMSYNC=0 WINEESYNC=0
      export WINEDLLPATH_PREPEND="$ENG/renderers/dxmt/wine"
      [ -f "$FW/libhbaudiobuf.dylib" ] && export DYLD_INSERT_LIBRARIES="$FW/libhbaudiobuf.dylib"
      ;;
    *)
      export WINEMSYNC=0 WINEESYNC=0
      ;;
  esac
}

game_running() { pgrep -f "$SHIPPING_EXE" >/dev/null 2>&1; }

wait_server() { # [max seconds]  wait for the prefix's Windows session to end
  [ -x "$WINESERVER" ] || return 0
  [ -d "$PREFIX" ] || return 0
  local max="${1:-90}" i=0 pid
  WINEPREFIX="$PREFIX" "$WINESERVER" -w >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ $i -lt "$max" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; return 1; fi
  return 0
}

stop_server() { # end every Windows program in the prefix
  [ -x "$WINESERVER" ] || return 0
  [ -d "$PREFIX" ] || return 0
  WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1
  wait_server 15
  return 0
}

# Run a command in the background, ticking an elapsed-time counter
run_ticker() { # percent message command...
  local pct="$1" msg="$2" t=0 pid
  shift 2
  "$@" >> "$LOGS/setup.log" 2>&1 &
  pid=$!
  echo "$pid" > "$STATE/child.pid"
  while kill -0 "$pid" 2>/dev/null; do
    progress "$pct" "$msg ($(fmt_time $t))"
    sleep 1
    t=$((t + 1))
  done
  wait "$pid"
  local rc=$?
  rm -f "$STATE/child.pid"
  return $rc
}

benign_rc() { # Windows installers: 0 ok, 1638->102 already newer, 3010->194 reboot wanted
  case "$1" in 0|102|194) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------
download() { # url dest sha256 size label from% to%
  local url="$1" dest="$2" sha="$3" size="$4" label="$5" from="$6" to="$7"
  local part="$dest.part" attempt=1 pid rc have pct

  if [ -f "$dest" ]; then
    if [ -z "$sha" ] || sha_ok "$dest" "$sha"; then progress "$to" "$label - already downloaded"; return 0; fi
    rm -f "$dest"
  fi
  if [ -n "$sha" ] && [ -f "$part" ] && [ "$size" -gt 0 ] && [ "$(fsize "$part")" -ge "$size" ]; then
    if sha_ok "$part" "$sha"; then mv -f "$part" "$dest"; return 0; fi
    rm -f "$part"
  fi

  while [ $attempt -le 3 ]; do
    if [ -n "$DFM_TEST_MIRROR" ] && [ -f "$DFM_TEST_MIRROR/$(basename "$dest")" ]; then
      cp -f "$DFM_TEST_MIRROR/$(basename "$dest")" "$part"
      rc=$?
    else
      curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -C - -o "$part" "$url" >> "$LOGS/download.log" 2>&1 &
      pid=$!
      echo "$pid" > "$STATE/child.pid"
      while kill -0 "$pid" 2>/dev/null; do
        have=$(fsize "$part")
        if [ "$size" -gt 0 ] 2>/dev/null; then
          pct=$(( from + (to - from) * have / size ))
          [ "$pct" -gt "$to" ] && pct=$to
          progress "$pct" "$label - $(( have / 1048576 )) of $(( size / 1048576 )) MB"
        else
          progress -1 "$label - $(( have / 1048576 )) MB"
        fi
        sleep 1
      done
      wait "$pid"
      rc=$?
      rm -f "$STATE/child.pid"
    fi
    if [ "$rc" -ne 0 ]; then
      log "download attempt $attempt failed (curl $rc): $url"
      # 33/36: the server refused to resume, so start over next time
      if [ "$rc" -eq 33 ] || [ "$rc" -eq 36 ] || [ "$rc" -eq 22 ]; then rm -f "$part"; fi
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi
    if [ -n "$sha" ] && ! sha_ok "$part" "$sha"; then
      log "checksum mismatch: $url"
      rm -f "$part"
      attempt=$((attempt + 1))
      continue
    fi
    mv -f "$part" "$dest"
    progress "$to" "$label - done"
    return 0
  done
  fail "Download failed: $label. Check your internet connection and try again (finished parts are kept)."
}

# ---------------------------------------------------------------------------
# Setup: engine, Windows environment, runtimes
# ---------------------------------------------------------------------------
install_engine() {
  download "$WINE_URL" "$DL/wine-engine.tar.gz" "$WINE_SHA" "$WINE_SIZE" "Downloading Wine 11 engine" 2 58 || return 1
  download "$RT_URL" "$DL/runtime.tar.xz" "$RT_SHA" "$RT_SIZE" "Downloading runtime libraries" 58 72 || return 1
  download "$DXMT_URL" "$DL/dxmt.tar.gz" "$DXMT_SHA" "$DXMT_SIZE" "Downloading DXMT (Direct3D to Metal)" 72 76 || return 1
  download "$MVK_URL" "$DL/moltenvk.tar.gz" "$MVK_SHA" "$MVK_SIZE" "Downloading MoltenVK" 76 77 || return 1
  download "$ABUF_URL" "$DL/audiobuf.tar.xz" "$ABUF_SHA" "$ABUF_SIZE" "Downloading audio fix" 77 77 || return 1

  local tmp
  tmp=$(mktemp -d "$AS/unpack.XXXXXX") || { fail "Couldn't create a temporary folder."; return 1; }

  progress -1 "Unpacking the Wine engine..."
  if ! tar -xzf "$DL/wine-engine.tar.gz" -C "$tmp" >> "$LOGS/setup.log" 2>&1 || [ ! -f "$tmp/engine/bin/wine" ]; then
    rm -rf "$tmp"; fail "Couldn't unpack the Wine engine. Is the disk full?"; return 1
  fi

  progress -1 "Unpacking runtime libraries..."
  mkdir -p "$tmp/rt"
  if ! tar -xJf "$DL/runtime.tar.xz" -C "$tmp/rt" "$RT_SUBPATH" >> "$LOGS/setup.log" 2>&1 || [ ! -d "$tmp/rt/$RT_SUBPATH" ]; then
    rm -rf "$tmp"; fail "Couldn't unpack the runtime libraries."; return 1
  fi
  rm -rf "$tmp/frameworks"
  mv "$tmp/rt/$RT_SUBPATH" "$tmp/frameworks"
  # D3DMetal (Apple-licensed) draws Dungeons' 3D world black, so it isn't kept
  rm -rf "$tmp/rt" "$tmp/frameworks/renderer/d3dmetal" "$tmp/frameworks/renderer/apple_gptk" \
         "$tmp/frameworks/SikarugirSdk.framework"

  progress -1 "Installing DXMT..."
  mkdir -p "$tmp/x" "$tmp/renderers/dxmt"
  if ! tar -xzf "$DL/dxmt.tar.gz" -C "$tmp/x" >> "$LOGS/setup.log" 2>&1 || [ ! -f "$tmp/x/highball/x86_64-windows/d3d11.dll" ]; then
    rm -rf "$tmp"; fail "Couldn't unpack DXMT."; return 1
  fi
  rm -rf "$tmp/renderers/dxmt/wine"
  mv "$tmp/x/highball" "$tmp/renderers/dxmt/wine"
  rm -rf "$tmp/x"

  mkdir -p "$tmp/x"
  tar -xzf "$DL/moltenvk.tar.gz" -C "$tmp/x" libMoltenVK.dylib >> "$LOGS/setup.log" 2>&1 \
    && [ -f "$tmp/x/libMoltenVK.dylib" ] && mv -f "$tmp/x/libMoltenVK.dylib" "$tmp/frameworks/libMoltenVK.dylib"
  tar -xJf "$DL/audiobuf.tar.xz" -C "$tmp/x" libhbaudiobuf.dylib >> "$LOGS/setup.log" 2>&1 \
    && [ -f "$tmp/x/libhbaudiobuf.dylib" ] && mv -f "$tmp/x/libhbaudiobuf.dylib" "$tmp/frameworks/libhbaudiobuf.dylib"
  rm -rf "$tmp/x"

  printf '%s\n' "$ENGINE_ID" > "$tmp/.dfm-ready"

  stop_server
  rm -rf "$ENG.old"
  [ -d "$ENG" ] && mv "$ENG" "$ENG.old"
  if ! mv "$tmp" "$ENG"; then
    [ -d "$ENG.old" ] && mv "$ENG.old" "$ENG"
    rm -rf "$tmp"; fail "Couldn't put the engine in place."; return 1
  fi
  rm -rf "$ENG.old"
  rm -f "$DL/wine-engine.tar.gz" "$DL/runtime.tar.xz" "$DL/dxmt.tar.gz" "$DL/moltenvk.tar.gz" "$DL/audiobuf.tar.xz"
  log "engine $ENGINE_ID installed"
  return 0
}

make_prefix() {
  if [ -f "$PREFIX_MARK" ] && [ "$(cat "$PREFIX_MARK")" = "$ENGINE_ID" ]; then return 0; fi
  mkdir -p "$PREFIX"
  wine_env setup
  run_ticker -1 "Preparing the Windows environment - the first time takes a few minutes" "$WINE" wineboot -u
  local rc=$?
  wait_server 90 || stop_server
  if [ ! -f "$PREFIX/drive_c/windows/system32/kernel32.dll" ]; then
    fail "Creating the Windows environment failed (code $rc). Choose More > Show Log for details."
    return 1
  fi
  mkdir -p "$PREFIX/drive_c/Games"
  printf '%s\n' "$ENGINE_ID" > "$PREFIX_MARK"
  log "prefix ready (wineboot rc $rc)"
  return 0
}

install_vcredist() { # [force]
  if [ "$1" != force ] && [ -f "$VCRUN_MARK" ]; then return 0; fi
  download "$VC64_URL" "$DL/VC_redist.x64.exe" "$VC64_SHA" 0 "Downloading Visual C++ runtime (64-bit)" 90 90 || return 1
  download "$VC86_URL" "$DL/VC_redist.x86.exe" "$VC86_SHA" 0 "Downloading Visual C++ runtime (32-bit)" 91 91 || return 1
  wine_env setup
  local rc
  run_ticker 92 "Installing Visual C++ runtime (64-bit)" "$WINE" "$DL/VC_redist.x64.exe" /install /quiet /norestart
  rc=$?
  benign_rc $rc || { fail "The Visual C++ runtime (64-bit) didn't install (code $rc)."; return 1; }
  run_ticker 95 "Installing Visual C++ runtime (32-bit)" "$WINE" "$DL/VC_redist.x86.exe" /install /quiet /norestart
  rc=$?
  benign_rc $rc || { fail "The Visual C++ runtime (32-bit) didn't install (code $rc)."; return 1; }

  # Prefer Microsoft's runtime DLLs over Wine's own (same as winetricks vcrun2022)
  progress 98 "Applying runtime settings..."
  local reg="$PREFIX/drive_c/dfm-vcrun.reg" d
  {
    printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n'
    for d in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids \
             vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do
      printf '"%s"="native,builtin"\r\n' "$d"
    done
  } > "$reg"
  "$WINE" reg import 'C:\dfm-vcrun.reg' >> "$LOGS/setup.log" 2>&1
  rc=$?
  rm -f "$reg"
  [ $rc -eq 0 ] || { fail "Couldn't apply the runtime settings (code $rc)."; return 1; }
  wait_server 60 || stop_server
  touch "$VCRUN_MARK"
  rm -f "$DL/VC_redist.x64.exe" "$DL/VC_redist.x86.exe"
  return 0
}

preflight() {
  [ -n "$DFM_TEST" ] && { echo ok; return 0; }
  is_mac || { echo "error|Dungeons for Mac only runs on macOS."; return 0; }
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || { echo "error|This needs a Mac with Apple silicon (M1 or newer)."; return 0; }
  local ver maj gb
  ver=$(sw_vers -productVersion 2>/dev/null)
  maj=${ver%%.*}
  case "$maj" in ''|*[!0-9]*) maj=0 ;; esac
  [ "$maj" -ge 14 ] || { echo "error|macOS 14 Sonoma or newer is needed. This Mac has macOS $ver."; return 0; }
  gb=$(free_gb "$HOME")
  [ "${gb:-0}" -ge 4 ] || { echo "error|Setup needs about 4 GB of free disk space (this Mac has ${gb:-0} GB free)."; return 0; }
  if [ ! -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ] && ! /usr/bin/pgrep -q oahd 2>/dev/null; then
    echo "rosetta|missing"; return 0
  fi
  echo ok
}

job_setup() {
  mkdirs
  progress 1 "Checking this Mac..."
  local pf; pf=$(preflight)
  case "$pf" in
    ok) ;;
    rosetta*) fail "Rosetta 2 isn't installed. Open the app again and choose Install Rosetta."; return 1 ;;
    *) fail "${pf#error|}"; return 1 ;;
  esac
  if [ ! -f "$READY_MARK" ] || [ "$(cat "$READY_MARK")" != "$ENGINE_ID" ]; then
    install_engine || return 1
  fi
  install_store_engine || return 1
  install_client || return 1
  progress 86 "Preparing the Windows environment..."
  make_prefix || return 1
  install_vcredist || return 1
  progress 100 "Done"
  okmsg "Setup finished. Next, sign in with the Microsoft account that owns Minecraft Dungeons."
  return 0
}

job_repair() {
  [ -f "$READY_MARK" ] || { fail "Run setup first."; return 1; }
  progress -1 "Stopping Windows programs..."
  stop_server
  rm -f "$PREFIX_MARK"
  make_prefix || return 1
  install_vcredist force || return 1
  progress 100 "Done"
  okmsg "The Windows layer was repaired. Your game and saves were not touched."
  return 0
}

# ---------------------------------------------------------------------------
# Finding and adding the game
# ---------------------------------------------------------------------------
is_store_dir() { # store/Game Pass package markers in a folder
  [ -d "$1" ] || return 1
  find "$1" -maxdepth 1 \( -iname 'AppxManifest.xml' -o -iname 'MicrosoftGame.config' -o -iname 'AppxSignature.p7x' -o -iname 'AppxBlockMap.xml' \) 2>/dev/null | grep -q .
}

find_shipping() { # first game exe under a folder
  find "$1" -maxdepth "${2:-7}" -type f -iname "$SHIPPING_FIND" 2>/dev/null | head -n 1
}

game_root_of() { # .../<root>/Dungeons/Binaries/Win64/<exe>  ->  <root>
  (cd "$(dirname "$1")/../../.." 2>/dev/null && pwd)
}

# detect <folder>  ->  kind|sizeMB|root|sameVolume   (kind: launcher, store, none)
cmd_detect() {
  local dir="${1%/}" exe root kind=launcher mb same=0
  [ -n "$dir" ] || dir="/"
  if [ ! -d "$dir" ]; then echo "none|0||0"; return 0; fi
  exe=$(find_shipping "$dir")
  if [ -z "$exe" ]; then
    if is_store_dir "$dir" || find "$dir" -maxdepth 3 \( -iname 'AppxManifest.xml' -o -iname 'MicrosoftGame.config' \) 2>/dev/null | grep -q .; then
      echo "store|0|$dir|0"
    else
      echo "none|0||0"
    fi
    return 0
  fi
  root=$(game_root_of "$exe")
  [ -n "$root" ] || { echo "none|0||0"; return 0; }
  if is_store_dir "$root" || is_store_dir "$(dirname "$root")" || is_store_dir "$dir"; then kind=store; fi
  case "$root$dir" in *Microsoft.Lovika*|*WindowsApps*) kind=store ;; esac
  mb=$(du -sm "$root" 2>/dev/null | awk '{print $1}')
  mkdirs
  [ "$(devid "$root")" = "$(devid "$AS")" ] && same=1
  echo "$kind|${mb:-0}|$root|$same"
}

register_game() { # exe path
  local exe="$1" root
  root=$(game_root_of "$exe")
  conf_set game_exe "$exe"
  conf_set game_root "$root"
  rm -f "$STATE/last_exit"
  log "game registered: $exe"
}

job_import() { # folder copy|move [force]
  local src="$1" how="${2:-copy}" force="$3" info kind mb root same need gb
  [ -f "$PREFIX_MARK" ] || { fail "Run setup first."; return 1; }
  progress -1 "Looking at the folder..."
  info=$(cmd_detect "$src")
  kind=$(printf '%s' "$info" | cut -d'|' -f1)
  mb=$(printf '%s' "$info" | cut -d'|' -f2)
  root=$(printf '%s' "$info" | cut -d'|' -f3)
  same=$(printf '%s' "$info" | cut -d'|' -f4)
  if [ "$kind" = none ] || [ -z "$root" ]; then
    fail "No Minecraft Dungeons files were found there. Pick the folder that contains Dungeons.exe."
    return 1
  fi
  if [ "$kind" = store ] && [ "$force" != force ]; then
    fail "That's the Microsoft Store version, which can't run outside Windows. The Launcher version is needed."
    return 1
  fi
  if game_running; then fail "Quit Minecraft Dungeons first."; return 1; fi

  case "$root" in
    "$GAME_DIR")
      register_game "$(find_shipping "$GAME_DIR")"
      okmsg "Minecraft Dungeons is ready. Press Play!"
      return 0 ;;
  esac

  mkdir -p "$PREFIX/drive_c/Games"
  rm -rf "$GAME_DIR.partial"
  # A moved folder is the user's only copy, so it gets its own name that
  # Cancel never deletes.
  local staged="$GAME_DIR.partial"

  if [ "$how" = move ] && [ "$same" = 1 ]; then
    progress -1 "Moving the game files..."
    staged="$GAME_DIR.incoming"
    if [ -d "$staged" ]; then fail "A previous move is still at $staged. Remove it or add that folder instead."; return 1; fi
    mv "$root" "$staged" || { fail "Couldn't move the game folder. Try Copy instead."; return 1; }
  else
    need=$(( ${mb:-0} / 1024 + 1 ))
    gb=$(free_gb "$AS")
    if [ "${gb:-0}" -lt "$need" ]; then
      fail "Not enough free space: the game needs about $need GB and this Mac has ${gb:-0} GB free."
      return 1
    fi
    local total have pid pct
    total=$(du -sk "$root" 2>/dev/null | awk '{print $1}')
    [ "${total:-0}" -gt 0 ] || total=1
    copy_tree "$root" "$GAME_DIR.partial" >> "$LOGS/setup.log" 2>&1 &
    pid=$!
    echo "$pid" > "$STATE/child.pid"
    while kill -0 "$pid" 2>/dev/null; do
      have=$(du -sk "$GAME_DIR.partial" 2>/dev/null | awk '{print $1}')
      pct=$(( ${have:-0} * 100 / total ))
      [ "$pct" -gt 99 ] && pct=99
      progress "$pct" "Copying game files - $(( ${have:-0} / 1024 )) of $(( total / 1024 )) MB"
      sleep 2
    done
    wait "$pid"
    local rc=$?
    rm -f "$STATE/child.pid"
    if [ $rc -ne 0 ]; then
      rm -rf "$GAME_DIR.partial"
      fail "Copying failed (code $rc). Is the drive still connected and is there enough space?"
      return 1
    fi
  fi

  local exe
  exe=$(find_shipping "$staged")
  if [ -z "$exe" ]; then
    fail "The copy looks incomplete (no $SHIPPING_EXE). Please try again."
    return 1
  fi
  rm -rf "$GAME_DIR.old"
  [ -d "$GAME_DIR" ] && mv "$GAME_DIR" "$GAME_DIR.old"
  mv "$staged" "$GAME_DIR" || { fail "Couldn't put the game in place."; return 1; }
  rm -rf "$GAME_DIR.old"
  register_game "$(find_shipping "$GAME_DIR")"
  progress 100 "Done"
  if [ "$kind" = store ]; then
    okmsg "Copied. If the game says it can't verify ownership, this Store copy can't run outside Windows."
  else
    okmsg "Minecraft Dungeons is ready. Press Play!"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Microsoft Store copy
# ---------------------------------------------------------------------------
fetch_build() { # file dest label from to   (sha from <file>.sha256 in the same release)
  local sha
  sha=$(curl -fsSL --retry 3 "$DFM_BUILDS/$1.sha256" 2>>"$LOGS/download.log" | awk '{print $1}')
  case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *)
    fail "No Mac build is published yet (github.com/MrStickman202/dungeons-for-mac). Try again later."; return 1 ;; esac
  printf '%s' "$sha" > "$2.expected"
  download "$DFM_BUILDS/$1" "$2" "$sha" 0 "$3" "$4" "$5"
}

install_store_engine() { # swap Highball's Wine for the Dungeons for Mac build (keeps DXMT etc.)
  local tmp have want
  want=$(curl -fsSL --retry 3 "$DFM_BUILDS/dfm-engine.tar.gz.sha256" 2>/dev/null | awk '{print $1}')
  have=$(cat "$STORE_ENGINE_MARK" 2>/dev/null)
  if [ -n "$have" ] && { [ -z "$want" ] || [ "$have" = "$want" ]; }; then return 0; fi
  fetch_build dfm-engine.tar.gz "$DL/dfm-engine.tar.gz" "Downloading the Xbox-capable engine" 2 40 || return 1
  want=$(cat "$DL/dfm-engine.tar.gz.expected")
  tmp=$(mktemp -d "$AS/unpack.XXXXXX") || { fail "Couldn't create a temporary folder."; return 1; }
  progress -1 "Unpacking the engine..."
  if ! tar -xzf "$DL/dfm-engine.tar.gz" -C "$tmp" >> "$LOGS/setup.log" 2>&1 \
     || [ ! -x "$tmp/engine/bin/wine" ] || [ ! -f "$tmp/engine/lib/wine/x86_64-windows/xgameruntime.dll" ]; then
    rm -rf "$tmp"; fail "The engine download looks incomplete."; return 1
  fi
  stop_server
  rm -rf "$ENG/engine.old"
  [ -d "$ENG/engine" ] && mv "$ENG/engine" "$ENG/engine.old"
  mv "$tmp/engine" "$ENG/engine" || { [ -d "$ENG/engine.old" ] && mv "$ENG/engine.old" "$ENG/engine"; rm -rf "$tmp"; fail "Couldn't put the engine in place."; return 1; }
  rm -rf "$ENG/engine.old" "$tmp" "$DL/dfm-engine.tar.gz" "$DL/dfm-engine.tar.gz.expected"
  printf '%s\n' "$want" > "$STORE_ENGINE_MARK"
  rm -f "$PREFIX_MARK"     # the new Wine build updates the prefix once
  log "store engine $want installed"
}

install_client() {
  local want have tmp
  want=$(curl -fsSL --retry 3 "$DFM_BUILDS/dfm-client.tar.gz.sha256" 2>/dev/null | awk '{print $1}')
  have=$(cat "$CLIENT_DIR/.sha" 2>/dev/null)
  if [ -x "$XCLI" ] && [ -n "$have" ] && { [ -z "$want" ] || [ "$have" = "$want" ]; }; then return 0; fi
  fetch_build dfm-client.tar.gz "$DL/dfm-client.tar.gz" "Downloading the Microsoft sign-in client" 40 45 || return 1
  want=$(cat "$DL/dfm-client.tar.gz.expected")
  tmp=$(mktemp -d "$AS/unpack.XXXXXX") || return 1
  tar -xzf "$DL/dfm-client.tar.gz" -C "$tmp" >> "$LOGS/setup.log" 2>&1 && [ -x "$tmp/client/xodus-cli" ] \
    || { rm -rf "$tmp"; fail "The sign-in client download looks incomplete."; return 1; }
  rm -rf "$CLIENT_DIR"; mv "$tmp/client" "$CLIENT_DIR"; rm -rf "$tmp" "$DL/dfm-client.tar.gz" "$DL/dfm-client.tar.gz.expected"
  if is_mac; then /usr/bin/xattr -dr com.apple.quarantine "$CLIENT_DIR" 2>/dev/null; fi
  printf '%s\n' "$want" > "$CLIENT_DIR/.sha"
}

client_env() { # isolated runtime/state folders for the client and its service
  # Short on purpose: a Unix socket path is limited to 104 bytes on macOS
  export XODUS_RUNTIME_DIR="/tmp/dfm-$(id -u)"
  export XDG_STATE_HOME="$AS/state/xodus" XDG_DATA_HOME="$AS/state/xodus-data" XDG_CACHE_HOME="$AS/state/xodus-cache"
  mkdir -p "$XODUS_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
  chmod 700 "$XODUS_RUNTIME_DIR" 2>/dev/null
}

service_up() {
  [ -S "/tmp/dfm-$(id -u)/xodus.sock" ] && pgrep -f "$XSVC" >/dev/null 2>&1
}

start_service() {
  client_env
  service_up && return 0
  [ -O "$XODUS_RUNTIME_DIR" ] || { echo "$XODUS_RUNTIME_DIR is not ours" >> "$LOGS/xodus-service.log"; return 1; }
  rm -f "$XODUS_RUNTIME_DIR/xodus.sock"
  ( trap '' HUP; exec "$XSVC" ) >> "$LOGS/xodus-service.log" 2>&1 < /dev/null &
  local i=0
  while [ $i -lt 20 ] && [ ! -S "$XODUS_RUNTIME_DIR/xodus.sock" ]; do sleep 0.5; i=$((i + 1)); done
  [ -S "$XODUS_RUNTIME_DIR/xodus.sock" ]
}

store_config() { find "$STORE_DIR" -maxdepth 1 -type f -iname 'microsoftgame.config' 2>/dev/null | head -n 1; }

store_exe() { # first <Executable Name="..."> in MicrosoftGame.config, as the package writes it
  local cfg; cfg=$(store_config)
  [ -n "$cfg" ] || return 1
  tr -d '\r' < "$cfg" | tr '\n' ' ' | sed -n 's/.*<Executable[^>]*Name="\([^"]*\)".*/\1/p' | head -n 1
}

store_ready() { [ -f "$STORE_DIR/.xodus-streaming.msixvc" ] && [ -n "$(conf_get store_exe "")" ]; }

job_signin() {
  [ -x "$XCLI" ] || { fail "Run setup first."; return 1; }
  client_env
  progress -1 "Sign in with your Microsoft account in the window that opened..."
  "$XCLI" login >> "$LOGS/signin.log" 2>&1
  local rc=$? who
  who=$("$XCLI" account 2>>"$LOGS/signin.log" | head -n 3 | tr '\n' ' ')
  if [ $rc -ne 0 ] || [ -z "$who" ]; then
    fail "Sign-in didn't finish (code $rc). Try again, or choose More > Show Log."
    return 1
  fi
  conf_set signed_in 1
  okmsg "Signed in: $who"
}

job_storeinstall() {
  [ -x "$XCLI" ] || { fail "Run setup first."; return 1; }
  [ "$(conf_get signed_in 0)" = 1 ] || { fail "Sign in with your Microsoft account first."; return 1; }
  local gb; gb=$(free_gb "$AS")
  [ "${gb:-0}" -ge 14 ] || { fail "Downloading Minecraft Dungeons needs about 14 GB free (this Mac has ${gb:-0} GB)."; return 1; }
  client_env
  mkdir -p "$STORE_DIR"
  progress 0 "Asking Microsoft for your copy of Minecraft Dungeons..."
  : > "$LOGS/store-download.log"
  ( XODUS_PROGRESS=json exec "$XCLI" streaming "$STORE_PRODUCT" "$STORE_DIR" ) > "$STATE/stream.out" 2>> "$LOGS/store-download.log" &
  local pid=$! line done_b total pct
  echo "$pid" > "$STATE/child.pid"
  while kill -0 "$pid" 2>/dev/null; do
    line=$(grep -o '"progress":{"done":[0-9]*,"total":[0-9]*' "$STATE/stream.out" 2>/dev/null | tail -n 1)
    done_b=$(printf '%s' "$line" | sed -n 's/.*"done":\([0-9]*\).*/\1/p')
    total=$(printf '%s' "$line" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      pct=$(( done_b * 100 / total ))
      progress "$pct" "Downloading Minecraft Dungeons from Microsoft - $(( done_b / 1048576 )) of $(( total / 1048576 )) MB"
    fi
    sleep 1
  done
  wait "$pid"; local rc=$?
  rm -f "$STATE/child.pid"
  cat "$STATE/stream.out" >> "$LOGS/store-download.log" 2>/dev/null
  if [ $rc -ne 0 ] || [ ! -f "$STORE_DIR/.xodus-streaming.msixvc" ]; then
    if grep -qiE 'licen[cs]e|entitle|not owned|forbidden|403' "$LOGS/store-download.log"; then
      fail "Microsoft says this account doesn't own Minecraft Dungeons for Windows. Sign in with the account that bought it."
    else
      fail "The download stopped (code $rc). Press Download again to resume."
    fi
    return 1
  fi
  local exe; exe=$(store_exe)
  [ -n "$exe" ] || { fail "Downloaded, but MicrosoftGame.config names no executable."; return 1; }
  conf_set store_exe "$exe"
  conf_set game_mode store
  progress 100 "Done"
  okmsg "Minecraft Dungeons is downloaded. Press Play!"
}

play_store() {
  local exe glog
  exe=$(conf_get store_exe "")
  start_service || { echo "error|The Xbox sign-in service didn't start. Choose More > Show Log."; return 0; }
  stop_server
  rotate_logs
  glog="$LOGS/game-$(date +%Y%m%d-%H%M%S).log"
  printf 'Dungeons for Mac %s - Store copy, exe=%s\nrenderer=%s fps=%s sharp=%s sync=%s\n----\n' \
    "$DFM_VERSION" "$exe" "$(conf_get renderer dxmt)" "$(conf_get fps 60)" "$(conf_get sharp 0)" "$(conf_get sync msync)" > "$glog"
  rm -f "$STATE/last_exit"
  mkdir -p "$AS/app"
  printf '#!/bin/bash\nexec /bin/bash %s __wine "$@"\n' "'$SELF'" > "$AS/app/wine-shim.sh" && chmod 755 "$AS/app/wine-shim.sh"
  cd "$STORE_DIR" || { echo "error|The game folder is missing."; return 0; }
  (
    trap '' HUP
    start=$(date +%s)
    # The client decrypts the game onto a RAM disk and starts "$SELF __wine",
    # which sets the Metal/DXMT environment and execs this engine's wine.
    "$XCLI" run -e "$exe" "$STORE_DIR" "$AS/app/wine-shim.sh"
    code=$?
    echo "$code $(( $(date +%s) - start ))" > "$STATE/last_exit"
  ) >> "$glog" 2>&1 < /dev/null &
  log "play (store): $exe"
  echo "ok|Starting Minecraft Dungeons."
}

cmd_wine_shim() { # called by xodus-cli as its "wine": inherited fds stay open across exec
  wine_env game
  client_env
  export WINE_GAMEINPUT=1
  exec "$WINE" "$@"
}

cmd_find_game() { # look for a copy the Minecraft Launcher installed inside the prefix
  local exe
  exe=$(find "$PREFIX/drive_c" -path "$PREFIX/drive_c/windows" -prune -o -type f -iname "$SHIPPING_FIND" -print 2>/dev/null | head -n 1)
  if [ -n "$exe" ]; then register_game "$exe"; echo "ok|$exe"; else echo "none|"; fi
}

# ---------------------------------------------------------------------------
# Experimental: Mojang's Windows launcher inside the prefix
# ---------------------------------------------------------------------------
job_mclauncher() {
  [ -f "$PREFIX_MARK" ] || { fail "Run setup first."; return 1; }
  download "$MCL_URL" "$DL/MinecraftInstaller.msi" "" 0 "Downloading the Minecraft Launcher" 0 40 || return 1
  if [ "$(fsize "$DL/MinecraftInstaller.msi")" -lt 1000000 ]; then
    rm -f "$DL/MinecraftInstaller.msi"
    fail "Mojang's download didn't look like an installer. The legacy launcher may no longer be offered."
    return 1
  fi
  stop_server
  wine_env setup
  cp -f "$DL/MinecraftInstaller.msi" "$PREFIX/drive_c/dfm-MinecraftInstaller.msi"
  run_ticker -1 "Installing the Minecraft Launcher" "$WINE" msiexec /i 'C:\dfm-MinecraftInstaller.msi' /qn
  local rc=$?
  wait_server 60 || stop_server
  rm -f "$PREFIX/drive_c/dfm-MinecraftInstaller.msi"
  if [ ! -f "$MCL_EXE" ]; then
    fail "The Minecraft Launcher didn't install (code $rc)."
    return 1
  fi
  progress 100 "Done"
  okmsg "Minecraft Launcher installed. Open it from More > Minecraft Launcher."
  return 0
}

cmd_launcher_run() {
  [ -f "$MCL_EXE" ] || { echo "error|The Minecraft Launcher isn't installed."; return 0; }
  if game_running; then echo "error|Quit Minecraft Dungeons first."; return 0; fi
  stop_server
  wine_env launcher
  (
    trap '' HUP
    cd "$(dirname "$MCL_EXE")" && "$WINE" "$MCL_EXE"
  ) > "$LOGS/launcher.log" 2>&1 < /dev/null &
  echo "ok|Opening the Minecraft Launcher."
}

# ---------------------------------------------------------------------------
# Playing
# ---------------------------------------------------------------------------
rotate_logs() { # keep the 4 newest game logs (plus the one about to start)
  ls -t "$LOGS"/game-*.log 2>/dev/null | tail -n +5 | while IFS= read -r f; do rm -f "$f"; done
}

cmd_play() {
  if [ ! -f "$READY_MARK" ] || [ ! -f "$PREFIX_MARK" ]; then echo "error|Setup hasn't finished yet."; return 0; fi
  local exe target args root glog
  if [ "$(conf_get game_mode launcher)" = store ] && store_ready; then
    if game_running || pgrep -f "$XCLI run" >/dev/null 2>&1; then echo "running|Minecraft Dungeons is already running."; return 0; fi
    if job_alive; then echo "error|Wait for the current task to finish first."; return 0; fi
    play_store
    return 0
  fi
  exe=$(conf_get game_exe "")
  if [ -z "$exe" ] || [ ! -f "$exe" ]; then echo "error|The game files are missing. Add the game folder again."; return 0; fi
  if game_running; then echo "running|Minecraft Dungeons is already running."; return 0; fi
  if job_alive; then echo "error|Wait for the current task to finish first."; return 0; fi

  # A Windows session left over from setup or the launcher would keep its own
  # sync mode; start the game on a fresh one.
  stop_server

  target="$exe"
  if [ "$(conf_get launch direct)" = bootstrap ]; then
    root=$(conf_get game_root "")
    [ -f "$root/Dungeons.exe" ] && target="$root/Dungeons.exe"
  fi
  args=$(conf_get args "")

  wine_env game
  rotate_logs
  glog="$LOGS/game-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "Dungeons for Mac $DFM_VERSION - engine $ENGINE_ID"
    echo "renderer=$(conf_get renderer dxmt) fps=$(conf_get fps 60) sharp=$(conf_get sharp 0) sync=$(conf_get sync msync) launch=$(conf_get launch direct)"
    echo "exe=$target args=$args"
    echo "WINEDLLPATH_PREPEND=$WINEDLLPATH_PREPEND"
    echo "DXMT_CONFIG=$DXMT_CONFIG WINEMSYNC=$WINEMSYNC"
    echo "----"
  } > "$glog"
  rm -f "$STATE/last_exit"
  cd "$(dirname "$target")" || { echo "error|Couldn't open the game folder."; return 0; }
  set -f
  (
    trap '' HUP
    start=$(date +%s)
    # shellcheck disable=SC2086
    "$WINE" "$target" $args
    code=$?
    end=$(date +%s)
    echo "$code $((end - start))" > "$STATE/last_exit"
  ) >> "$glog" 2>&1 < /dev/null &
  set +f
  log "play: $target"
  echo "ok|Starting Minecraft Dungeons."
}

cmd_stop() {
  wine_env setup
  stop_server
  echo "ok|Stopped."
}

# ---------------------------------------------------------------------------
# Saves, logs, diagnostics, uninstall
# ---------------------------------------------------------------------------
user_dir() {
  local u
  for u in "$PREFIX/drive_c/users/"*; do
    case "$(basename "$u")" in Public|'*') continue ;; esac
    [ -d "$u" ] && { printf '%s' "$u"; return 0; }
  done
  printf '%s' "$PREFIX/drive_c/users/$(id -un)"
}

saves_dir() { printf '%s' "$(user_dir)/Saved Games/Mojang Studios/Dungeons"; }
config_dir() { printf '%s' "$(user_dir)/AppData/Local/Dungeons"; }

cmd_open_saves() {
  local s; s=$(saves_dir)
  [ -d "$PREFIX/drive_c" ] || { echo "error|Run setup first."; return 0; }
  mkdir -p "$s"
  reveal "$s"
  echo "ok|$s"
}

cmd_backup_saves() {
  local s c dest found=0
  s=$(saves_dir); c=$(config_dir)
  dest="$HOME/Documents/Minecraft Dungeons Saves/Backup $(date '+%Y-%m-%d %H.%M.%S')"
  if [ -d "$s" ] && [ -n "$(ls -A "$s" 2>/dev/null)" ]; then
    mkdir -p "$dest" && copy_tree "$s" "$dest/Saved Games" || { echo "error|Couldn't copy the saves."; return 0; }
    found=1
  fi
  if [ -d "$c" ] && [ -n "$(ls -A "$c" 2>/dev/null)" ]; then
    mkdir -p "$dest" && copy_tree "$c" "$dest/Local AppData" || { echo "error|Couldn't copy the game settings."; return 0; }
    found=1
  fi
  if [ $found = 1 ]; then echo "ok|$dest"; else echo "none|No saves found yet."; fi
}

latest_log() {
  local f
  f=$(ls -t "$LOGS"/game-*.log 2>/dev/null | head -n 1)
  [ -n "$f" ] || f=$(ls -t "$LOGS"/*.log 2>/dev/null | head -n 1)
  printf '%s' "$f"
}

cmd_open_log() {
  local f; f=$(latest_log)
  if [ -n "$f" ]; then reveal "$f"; echo "ok|$f"; else echo "none|No logs yet."; fi
}

cmd_diag() {
  local dir out stamp
  stamp=$(date '+%Y%m%d-%H%M%S')
  dir=$(mktemp -d "${TMPDIR:-/tmp}/dfm-diag.XXXXXX") || { echo "error|Couldn't create a temp folder."; return 0; }
  mkdir -p "$dir/DungeonsForMac-diagnostics"
  {
    echo "Dungeons for Mac $DFM_VERSION, engine $ENGINE_ID"
    sw_vers 2>/dev/null
    sysctl -n machdep.cpu.brand_string hw.model hw.memsize 2>/dev/null
    echo "free GB: $(free_gb "$HOME")"
    echo; echo "== status"; cmd_status
    echo; echo "== settings"; cat "$CONF" 2>/dev/null
    echo; echo "== engine"; ls -la "$ENG" "$ENG/renderers/dxmt/wine/x86_64-windows" 2>/dev/null
    echo; echo "== game folder"; ls -la "$(conf_get game_root "")" 2>/dev/null
  } > "$dir/DungeonsForMac-diagnostics/summary.txt" 2>&1
  cp "$LOGS"/*.log "$dir/DungeonsForMac-diagnostics/" 2>/dev/null
  out="$HOME/Desktop/DungeonsForMac-diagnostics-$stamp.zip"
  (cd "$dir" && zip -qr "$out" DungeonsForMac-diagnostics) || { rm -rf "$dir"; echo "error|Couldn't write the report."; return 0; }
  rm -rf "$dir"
  reveal -R "$out"
  echo "ok|$out"
}

cmd_uninstall() {
  case "$AS" in
    */DungeonsForMac|*/DungeonsForMac/) ;;
    *) echo "error|Refusing to delete an unexpected folder: $AS"; return 0 ;;
  esac
  if [ -x "$WINESERVER" ]; then wine_env setup; stop_server; fi
  rm -rf "$AS"
  echo "ok|Removed."
}

# ---------------------------------------------------------------------------
# Background jobs (the window polls for progress)
# ---------------------------------------------------------------------------
job_alive() { [ -f "$STATE/job.pid" ] && kill -0 "$(cat "$STATE/job.pid" 2>/dev/null)" 2>/dev/null; }

kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$p" 2>/dev/null
}

cmd_start() { # job args...
  local job="$1"
  shift
  case "$job" in setup|repair|import|mclauncher|signin|storeinstall) ;; *) echo "error|unknown job $job"; return 0 ;; esac
  mkdirs
  if job_alive; then echo "busy|Another task is running."; return 0; fi
  rm -f "$STATE/result" "$STATE/okmsg" "$STATE/errmsg"
  progress -1 "Starting..."
  ( trap '' HUP; exec /bin/bash "$SELF" __job "$job" "$@" ) > /dev/null 2>&1 < /dev/null &
  echo "$!" > "$STATE/job.pid"
  log "job started: $job $*"
  echo "started|$job"
}

run_job() { # internal: runs inside the background process
  local name="$1" rc
  shift
  exec >> "$LOGS/job.log" 2>&1
  echo "== $(date) job $name $*"
  "job_$name" "$@"
  rc=$?
  if [ $rc -eq 0 ]; then
    printf 'done|ok|%s\n' "$(cat "$STATE/okmsg" 2>/dev/null)" > "$STATE/result.tmp"
  else
    printf 'done|error|%s\n' "$(cat "$STATE/errmsg" 2>/dev/null || echo 'Something went wrong. Choose More > Show Log.')" > "$STATE/result.tmp"
  fi
  mv -f "$STATE/result.tmp" "$STATE/result"
  log "job $name finished (rc $rc)"
}

cmd_poll() {
  if [ -f "$STATE/result" ]; then
    cat "$STATE/result"
    rm -f "$STATE/result" "$STATE/job.pid" "$STATE/progress"
    return 0
  fi
  if job_alive; then
    if [ -f "$STATE/progress" ]; then cat "$STATE/progress"; else echo "run|-1|Working..."; fi
    return 0
  fi
  sleep 1   # the job may have just finished
  if [ -f "$STATE/result" ]; then
    cat "$STATE/result"
    rm -f "$STATE/result" "$STATE/job.pid" "$STATE/progress"
  else
    rm -f "$STATE/job.pid" "$STATE/progress"
    echo "done|error|The task stopped unexpectedly. Choose More > Show Log for details."
  fi
}

cmd_cancel() {
  local pid
  pid=$(cat "$STATE/job.pid" 2>/dev/null)
  [ -n "$pid" ] && kill_tree "$pid"
  if [ -x "$WINESERVER" ]; then wine_env setup; stop_server; fi
  rm -f "$STATE/job.pid" "$STATE/progress" "$STATE/result" "$STATE/child.pid"
  rm -rf "$AS"/unpack.* "$GAME_DIR.partial"
  pkill -f "$XCLI streaming" 2>/dev/null
  log "job cancelled"
  echo "ok|cancelled"
}

# ---------------------------------------------------------------------------
# Status and settings for the window
# ---------------------------------------------------------------------------
cmd_status() {
  local engine=0 game=0 running=0 busy=0 launcher=0 exe
  [ -f "$READY_MARK" ] && [ "$(cat "$READY_MARK")" = "$ENGINE_ID" ] \
    && [ -f "$PREFIX_MARK" ] && [ -f "$VCRUN_MARK" ] && [ -f "$STORE_ENGINE_MARK" ] && [ -x "$XCLI" ] && engine=1
  exe=$(conf_get game_exe "")
  [ -n "$exe" ] && [ -f "$exe" ] && game=1
  if [ "$(conf_get game_mode launcher)" = store ] && store_ready; then game=1; fi
  game_running && running=1
  job_alive && busy=1
  [ -f "$MCL_EXE" ] && launcher=1
  echo "engine=$engine"
  echo "game=$game"
  echo "running=$running"
  echo "busy=$busy"
  echo "launcher=$launcher"
  echo "signed_in=$(conf_get signed_in 0)"
  echo "mode=$(conf_get game_mode launcher)"
  echo "renderer=$(conf_get renderer dxmt)"
  echo "fps=$(conf_get fps 60)"
  echo "sharp=$(conf_get sharp 0)"
  echo "hud=$(conf_get hud 0)"
  echo "sync=$(conf_get sync msync)"
  echo "launch=$(conf_get launch direct)"
  echo "args=$(conf_get args "")"
  if [ -f "$STATE/last_exit" ]; then
    local code secs
    read -r code secs < "$STATE/last_exit"
    echo "last_code=$code"
    echo "last_secs=$secs"
  fi
  echo "version=$DFM_VERSION"
}

cmd_set() { # key value
  local k="$1" v="$2"
  case "$k" in
    renderer) case "$v" in dxmt|dxvk|wined3d) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    fps)      case "$v" in 0|30|60|120) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    sharp|hud) case "$v" in 0|1) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    sync)     case "$v" in msync|esync|off) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    launch)   case "$v" in direct|bootstrap) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    args)     ;;
    *) echo "error|unknown setting"; return 0 ;;
  esac
  conf_set "$k" "$v"
  echo "ok|$k=$v"
}

cmd_reset_settings() {
  local k
  for k in renderer fps sharp hud sync launch args; do conf_unset "$k"; done
  echo "ok|defaults"
}

usage() {
  cat <<'EOF'
Dungeons for Mac core
  status | preflight | poll | cancel
  start setup | start repair | start import <folder> [copy|move] [force] | start mclauncher
  detect <folder> | find-game | play | stop | launcher-run
  set <key> <value> | reset-settings
  open-saves | backup-saves | open-log | diag | uninstall
EOF
}

# ---------------------------------------------------------------------------
cmd="$1"
[ $# -gt 0 ] && shift
mkdirs
case "$cmd" in
  __job)          run_job "$@" ;;
  __wine)         cmd_wine_shim "$@" ;;
  status)         cmd_status ;;
  preflight)      preflight ;;
  start)          cmd_start "$@" ;;
  poll)           cmd_poll ;;
  cancel)         cmd_cancel ;;
  detect)         cmd_detect "$1" ;;
  find-game)      cmd_find_game ;;
  play)           cmd_play ;;
  stop)           cmd_stop ;;
  launcher-run)   cmd_launcher_run ;;
  set)            cmd_set "$1" "$2" ;;
  reset-settings) cmd_reset_settings ;;
  open-saves)     cmd_open_saves ;;
  backup-saves)   cmd_backup_saves ;;
  open-log)       cmd_open_log ;;
  diag)           cmd_diag ;;
  uninstall)      cmd_uninstall ;;
  version)        echo "$DFM_VERSION" ;;
  ''|help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
exit 0
