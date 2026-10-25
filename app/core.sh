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
DFM_BUILD=14   # bumped by every app release; the launcher prefers the higher one

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
DFM_APPREL="${DFM_APPREL:-https://github.com/MrStickman202/dungeons-for-mac/releases/download/app-latest}"
CLIENT_DIR="$AS/client"
XCLI="$CLIENT_DIR/xodus-cli"
XSVC="$CLIENT_DIR/xodus-service"
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
  unset WINEDLLPATH_PREPEND DXMT_CONFIG DXMT_METALFX_SPATIAL_SWAPCHAIN MTL_HUD_ENABLED CX_D3DMETALPATH D3DM_MAX_FPS D3DM_ENABLE_METALFX
  unset DXVK_ASYNC DXVK_FRAME_RATE DYLD_INSERT_LIBRARIES
  ulimit -n 10240 2>/dev/null

  case "$1" in
    game)
      case "$(conf_get sync msync)" in
        esync) export WINEESYNC=1 WINEMSYNC=0 ;;
        off)   export WINEESYNC=0 WINEMSYNC=0 ;;
        *)     export WINEMSYNC=1 WINEESYNC=0 ;;
      esac
      local fps r; fps=$(conf_get fps 60)
      r=$(conf_get renderer dxmt)
      # A DirectX 12 game always takes D3DMetal; the Graphics setting is for DirectX 11 ones
      [ "${GAME_RENDERER_FOR_LAUNCH:-}" = d3dmetal ] && r=d3dmetal
      case "$r" in
        d3dmetal)
          # D3DMetal for 64-bit Direct3D 11/12, DXMT behind it for 32-bit Direct3D 11
          export WINEDLLPATH_PREPEND="$D3DM/wine:$ENG/renderers/dxmt/wine"
          export CX_D3DMETALPATH="$D3DM/external"
          export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_FALLBACK_LIBRARY_PATH:$D3DM/external"
          export DYLD_FALLBACK_FRAMEWORK_PATH="$DYLD_FALLBACK_FRAMEWORK_PATH:$D3DM/external"
          [ "$fps" != 0 ] && export D3DM_MAX_FPS="$fps" DXMT_CONFIG="d3d11.preferredMaxFrameRate=$fps;"
          # DLSS -> MetalFX: upscaling, and frame generation where the game offers DLSS Frame Generation
          [ "$(conf_get metalfx 0)" = 1 ] && export D3DM_ENABLE_METALFX=1
          ;;
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
          local up; up=$(upscale_setting)
          if [ "$up" != off ]; then
            # MetalFX spatial upscaling of the game's output: set the game to a lower
            # resolution and it is scaled up by this factor to the window
            export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
            cfg="${cfg}d3d11.metalSpatialUpscaleFactor=$up;"
          fi
          # DLSS -> MetalFX: the game sees an NVIDIA GPU and its DLSS option runs on MetalFX
          [ "$(conf_get metalfx 0)" = 1 ] && export DXMT_ENABLE_NVEXT=1
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

upscale_setting() { # off | 1.5 | 2  (older builds stored sharp=1 for 2x)
  local up; up=$(conf_get upscale "")
  if [ -z "$up" ]; then if [ "$(conf_get sharp 0)" = 1 ]; then up=2; else up=off; fi; fi
  echo "$up"
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
  # Wine itself: the Dungeons for Mac build (CrossOver 26.3 + Xbox runtime). Highball's
  # plain build ($WINE_URL) is the same tree without the Xbox patches.
  fetch_build dfm-engine.tar.gz "$DL/wine-engine.tar.gz" "Downloading the Wine 11 engine" 2 58 || return 1
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
  cp "$DL/wine-engine.tar.gz.expected" "$tmp/.dfm-store-engine" 2>/dev/null

  progress -1 "Unpacking runtime libraries..."
  mkdir -p "$tmp/rt"
  if ! tar -xJf "$DL/runtime.tar.xz" -C "$tmp/rt" "$RT_SUBPATH" >> "$LOGS/setup.log" 2>&1 || [ ! -d "$tmp/rt/$RT_SUBPATH" ]; then
    rm -rf "$tmp"; fail "Couldn't unpack the runtime libraries."; return 1
  fi
  rm -rf "$tmp/frameworks"
  mv "$tmp/rt/$RT_SUBPATH" "$tmp/frameworks"
  # D3DMetal (Apple-licensed) stays on disk but is only used for DirectX 12 games, and
  # only after the person accepts Apple's licence in the app
  rm -rf "$tmp/rt" "$tmp/frameworks/SikarugirSdk.framework"

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
  rm -f "$DL/wine-engine.tar.gz" "$DL/wine-engine.tar.gz.expected" "$DL/runtime.tar.xz" "$DL/dxmt.tar.gz" "$DL/moltenvk.tar.gz" "$DL/audiobuf.tar.xz"
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
  progress -1 "Checking for engine and sign-in client updates..."
  install_store_engine || return 1
  install_client || return 1
  progress -1 "Stopping Windows programs..."
  stop_server
  rm -f "$PREFIX_MARK"
  make_prefix || return 1
  install_vcredist force || return 1
  progress 100 "Done"
  okmsg "Updated and repaired. Your game and saves were not touched."
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
fetch_build() { # file dest label from to [base]  (sha from <file>.sha256 in the same release)
  local sha base="${6:-$DFM_BUILDS}"
  sha=$(curl -fsSL --retry 3 "$base/$1.sha256" 2>>"$LOGS/download.log" | awk '{print $1}')
  case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *)
    fail "No Mac build is published yet (github.com/MrStickman202/dungeons-for-mac). Try again later."; return 1 ;; esac
  printf '%s' "$sha" > "$2.expected"
  download "$base/$1" "$2" "$sha" 0 "$3" "$4" "$5"
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
  pkill -f "$XSVC" 2>/dev/null; sleep 1
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
  # a service without its socket is stuck: replace it
  pkill -f "$XSVC" >/dev/null 2>&1 && sleep 1
  rm -f "$XODUS_RUNTIME_DIR/xodus.sock"
  echo "$(date '+%F %T') starting the sign-in service" >> "$LOGS/xodus-service.log"
  ( trap '' HUP TERM; set -m; exec "$XSVC" ) >> "$LOGS/xodus-service.log" 2>&1 < /dev/null &
  local i=0
  # it reads the sign-in from the keychain first, which can wait on a macOS prompt
  while [ $i -lt 60 ] && [ ! -S "$XODUS_RUNTIME_DIR/xodus.sock" ]; do sleep 0.5; i=$((i + 1)); done
  [ -S "$XODUS_RUNTIME_DIR/xodus.sock" ] || { echo "$(date '+%F %T') the sign-in service made no socket in 30 s" >> "$LOGS/xodus-service.log"; return 1; }
}

# ---------------------------------------------------------------------------
# Games. Built in: Minecraft Dungeons, Minecraft Bedrock. More can be added by
# Microsoft Store product ID (Xbox PC / MSIXVC games only).
#   id|name|store product|renderer|setup steps|folder under games/
# ---------------------------------------------------------------------------
BUILTIN_GAMES="dungeons|Minecraft Dungeons|9P8MK4NC0LJB|dxmt||minecraft-dungeons-store
bedrock|Minecraft Bedrock (experimental)|9NBLGGH2JHXJ|d3dmetal|xcurl|minecraft-bedrock"

game_line() { # id -> its registry line
  local id="$1" c
  c=$(printf '%s\n' "$BUILTIN_GAMES" | grep -E "^$id\|" | head -n 1)
  [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
  c=$(conf_get "custom_$id" "")
  [ -n "$c" ] && printf '%s|%s|custom-%s\n' "$id" "$c" "$id"
}

game_ids() { # every known id, built-ins first
  printf '%s\n' "$BUILTIN_GAMES" | cut -d'|' -f1
  conf_get custom_games "" | tr ',' '\n' | grep -v '^$'
}

select_game() { # id: sets GAME_ID GAME_NAME STORE_PRODUCT GAME_RENDERER GAME_SETUP STORE_DIR EXE_KEY
  local line
  line=$(game_line "${1:-dungeons}")
  [ -n "$line" ] || return 1
  GAME_ID=$(printf '%s' "$line" | cut -d'|' -f1)
  GAME_NAME=$(printf '%s' "$line" | cut -d'|' -f2)
  STORE_PRODUCT=$(printf '%s' "$line" | cut -d'|' -f3)
  GAME_RENDERER=$(printf '%s' "$line" | cut -d'|' -f4)
  GAME_SETUP=$(printf '%s' "$line" | cut -d'|' -f5)
  STORE_DIR="$AS/games/$(printf '%s' "$line" | cut -d'|' -f6)"
  if [ "$GAME_ID" = dungeons ]; then EXE_KEY=store_exe; else EXE_KEY="store_exe_$GAME_ID"; fi
  [ -n "$GAME_RENDERER" ] || GAME_RENDERER=dxmt
  return 0
}
select_game dungeons

store_config() { find "$STORE_DIR" -maxdepth 1 -type f -iname 'microsoftgame.config' 2>/dev/null | head -n 1; }

store_exe() { # first <Executable Name="..."> in MicrosoftGame.config, as the package writes it
  local cfg; cfg=$(store_config)
  [ -n "$cfg" ] || return 1
  tr -d '\r' < "$cfg" | tr '\n' ' ' | sed -n 's/.*<Executable[^>]*Name="\([^"]*\)".*/\1/p' | head -n 1
}

store_ready() { [ -f "$STORE_DIR/.xodus-streaming.msixvc" ] && [ -n "$(conf_get "$EXE_KEY" "")" ]; }

cmd_games() { # id|name|state  (state: ready, notdownloaded, needs-licence)
  local id state
  for id in $(game_ids); do
    select_game "$id" || continue
    if store_ready; then state=ready; else state=notdownloaded; fi
    if [ "$GAME_RENDERER" = d3dmetal ] && [ "$(conf_get d3dmetal_license 0)" != 1 ]; then
      [ "$state" = ready ] && state=needs-licence
    fi
    printf '%s|%s|%s\n' "$GAME_ID" "$GAME_NAME" "$state"
  done
}

cmd_add_game() { # name product  -> adds a custom Store game
  local name="$1" product id list
  product=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]')
  name=$(printf '%s' "$name" | tr -d '|\n\r')
  [ ${#product} -eq 12 ] || { echo "error|A Store product ID has 12 letters and numbers, like 9NBLGGH2JHXJ."; return 0; }
  [ -n "$name" ] || name="Store game $product"
  id=$(printf '%s' "$product" | tr '[:upper:]' '[:lower:]')
  if game_ids | grep -qx "$id" || printf '%s\n' "$BUILTIN_GAMES" | cut -d'|' -f3 | grep -qx "$product"; then
    echo "error|That game is already in the list."; return 0
  fi
  # D3DMetal runs both DirectX 12 and 11, so it is the safe start for an unknown
  # title (most Xbox PC games are DirectX 12); the network fix only acts when
  # the game ships Microsoft's XCurl.dll, which most do.
  conf_set "custom_$id" "$name|$product|d3dmetal|xcurl"
  list=$(conf_get custom_games "")
  conf_set custom_games "${list:+$list,}$id"
  echo "ok|$id"
}

cmd_game_renderer() { # id dxmt|d3dmetal: graphics for an added game
  local id="$1" r="$2" c name product setup
  case "$r" in dxmt|d3dmetal) ;; *) echo "error|unknown graphics option"; return 0 ;; esac
  case "$id" in dungeons|bedrock|'') echo "error|This game's graphics are set by the app."; return 0 ;; esac
  c=$(conf_get "custom_$id" "")
  [ -n "$c" ] || { echo "error|unknown game"; return 0; }
  name=$(printf '%s' "$c" | cut -d'|' -f1); product=$(printf '%s' "$c" | cut -d'|' -f2); setup=$(printf '%s' "$c" | cut -d'|' -f4)
  conf_set "custom_$id" "$name|$product|$r|$setup"
  echo "ok|$r"
}

# --- Owned-games search ---------------------------------------------------------
# What the account owns comes from Microsoft's collections service (through the
# sign-in client); names and package formats come from the public Store catalog.
# Only MSIXVC packages (Xbox PC / GDK games) can run here; older Store apps (UWP)
# are counted but not listed.
CATALOG_URL="https://displaycatalog.mp.microsoft.com/v7.0/products"
LIBRARY_CACHE="$STATE/library.txt"

library_js() { # writes the JSON reader (JavaScript for Automation ships with macOS)
  cat > "$STATE/library.js" <<'JS'
ObjC.import('Foundation');
function read(p) { var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null); return s.isNil() ? '' : s.js; }
function run(argv) {
  var out = [], skip = ['Durable', 'Consumable', 'UnmanagedConsumable', 'Pass'];
  if (argv[0] === 'owned') {
    var j; try { j = JSON.parse(read(argv[1])); } catch (e) { return ''; }
    (j.items || []).forEach(function (i) {
      if (i.productId && i.status === 'Active' && skip.indexOf(i.productType || '') < 0) out.push(i.productId);
    });
    return out.join('\n');
  }
  for (var k = 1; k < argv.length; k++) {
    var c; try { c = JSON.parse(read(argv[k])); } catch (e) { continue; }
    (c.Products || []).forEach(function (p) {
      if (!p.ProductId) return;
      var lp = (p.LocalizedProperties || [])[0] || {};
      var title = String(lp.ProductTitle || p.ProductId).replace(/[|\r\n]+/g, ' ');
      var fmt = 'none', kids = [];
      (p.DisplaySkuAvailabilities || []).forEach(function (a) {
        var pr = (a.Sku || {}).Properties || {};
        (pr.Packages || []).forEach(function (pk) {
          var f = String(pk.PackageFormat || '');
          var pc = (pk.PlatformDependencies || []).some(function (d) { return d.PlatformName === 'Windows.Desktop' || d.PlatformName === 'Windows.Universal'; });
          if (!pc) return;
          if (f.toUpperCase() === 'MSIXVC') fmt = 'msixvc'; else if (fmt === 'none' && f) fmt = 'other';
        });
        var b = pr.BundledSkus;
        if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = null; } }
        (b || []).forEach(function (x) { if (x && x.BigId && kids.indexOf(x.BigId) < 0) kids.push(x.BigId); });
      });
      out.push(p.ProductId + '|' + title + '|' + fmt + '|' + kids.join(',') + '|' + String(p.ProductType || ''));
    });
  }
  return out.join('\n');
}
JS
}

catalog_rows() { # product ids on stdin -> id|title|format|children
  local ids batch n=0 f code out rc
  local files=()   # an array: these paths contain spaces ("Application Support")
  ids=$(tr -d '\r' | grep -E '^[A-Za-z0-9]{12}$' | sort -u)
  echo "catalog: $(printf '%s' "$ids" | grep -c .) ids" >> "$LOGS/library.log"
  [ -n "$ids" ] || return 0
  while [ -n "$ids" ]; do
    batch=$(printf '%s\n' "$ids" | head -n 20 | paste -sd, -)
    ids=$(printf '%s\n' "$ids" | tail -n +21)
    n=$((n + 1)); f="$STATE/catalog-$$-$n.json"
    code=$(/usr/bin/curl -sS --max-time 25 -o "$f" -w '%{http_code}' "$CATALOG_URL?bigIds=$batch&market=US&languages=en-us" 2>> "$LOGS/library.log")
    echo "catalog batch $n: HTTP $code, $(wc -c < "$f" 2>/dev/null | tr -d ' ') bytes" >> "$LOGS/library.log"
    if [ "$code" = 200 ]; then files[${#files[@]}]="$f"; else rm -f "$f"; fi
  done
  [ ${#files[@]} -gt 0 ] || return 0
  out=$(/usr/bin/osascript -l JavaScript "$STATE/library.js" catalog "${files[@]}" 2>> "$LOGS/library.log"); rc=$?
  echo "catalog: reader rc $rc, $(printf '%s' "$out" | tr '\r' '\n' | grep -c '|') rows" >> "$LOGS/library.log"
  rm -f "${files[@]}"
  printf '%s\n' "$out" | tr '\r' '\n'
}

library_build() { # -> $LIBRARY_CACHE as id|title|format
  local rows kids owned rc
  library_js
  : > "$LOGS/library.log"
  client_env
  "$XCLI" library --all --json > "$STATE/library.json" 2>> "$LOGS/library.log" || { echo "client: library failed" >> "$LOGS/library.log"; return 1; }
  echo "owned: $(wc -c < "$STATE/library.json" | tr -d ' ') bytes from Microsoft" >> "$LOGS/library.log"
  owned=$(/usr/bin/osascript -l JavaScript "$STATE/library.js" owned "$STATE/library.json" 2>> "$LOGS/library.log"); rc=$?
  owned=$(printf '%s\n' "$owned" | tr '\r' '\n')
  echo "owned: reader rc $rc, $(printf '%s' "$owned" | grep -c .) products" >> "$LOGS/library.log"
  if [ -z "$owned" ]; then
    # fallback without the JavaScript reader: the client prints one key per line
    owned=$(awk -F'"' '/"productId":/{id=$4} /"productType":/{t=$4} /"status":/{ if ($4=="Active" && t!="Durable" && t!="Consumable" && t!="Pass" && id!="") print id; id=""; t="" }' "$STATE/library.json")
    echo "owned: fallback found $(printf '%s' "$owned" | grep -c .) products" >> "$LOGS/library.log"
  fi
  rows=$(printf '%s\n' "$owned" | catalog_rows)
  # a bundle (like Minecraft: Java & Bedrock Edition) has no package of its own: look up what's in it
  kids=$(printf '%s\n' "$rows" | cut -d'|' -f4 | tr ',' '\n' | grep -v '^$')
  if [ -n "$kids" ]; then
    rows=$(printf '%s\n%s\n' "$rows" "$(printf '%s\n' "$kids" | catalog_rows)")
  fi
  # apps can ship as MSIXVC too, but only games are listed as runnable; the Minecraft
  # Launcher and Java Edition are Java launchers, not Xbox games, so they're left out
  printf '%s\n' "$rows" | grep '|' | awk -F'|' 'BEGIN{OFS="|"} !seen[$1]++ { if ($3=="msixvc" && $5!="" && $5!="Game") $3="app"; if ($1=="9PGW18NPBZV5" || $1=="9PJ8266BHFWN") $3="app"; print $1,$2,$3 }' \
    | sort -t'|' -k2,2f > "$LIBRARY_CACHE.new" && mv -f "$LIBRARY_CACHE.new" "$LIBRARY_CACHE"
  echo "library: $(grep -c '|msixvc$' "$LIBRARY_CACHE") runnable of $(grep -c . "$LIBRARY_CACHE")" >> "$LOGS/library.log"
}

cmd_library() { # [query] [refresh] -> ok|shown|others, then id|title|added rows
  local q="$1" refresh="$2" age rows shown others added id title fmt product
  [ -x "$XCLI" ] || { echo "error|Run setup first."; return 0; }
  [ "$(conf_get signed_in 0)" = 1 ] || { echo "error|Sign in with your Microsoft account first."; return 0; }
  age=999999
  [ -f "$LIBRARY_CACHE" ] && age=$(( $(date +%s) - $(stat -f %m "$LIBRARY_CACHE" 2>/dev/null || echo 0) ))
  if [ "$refresh" = refresh ] || [ "$age" -gt 900 ] || [ ! -s "$LIBRARY_CACHE" ]; then
    library_build || { echo "error|Couldn't get your games from Microsoft. Check your internet connection, or sign in again (More...)."; return 0; }
  fi
  [ -s "$LIBRARY_CACHE" ] || { echo "error|Microsoft didn't list any games for this account."; return 0; }
  rows=$(grep -i -F -- "$q" "$LIBRARY_CACHE" 2>/dev/null)
  [ -n "$q" ] || rows=$(cat "$LIBRARY_CACHE")
  shown=$(printf '%s\n' "$rows" | grep -c '|msixvc$')
  others=$(printf '%s\n' "$rows" | grep '|' | grep -vc '|msixvc$')
  echo "ok|$shown|$others"
  printf '%s\n' "$rows" | grep '|msixvc$' | while IFS='|' read -r product title fmt; do
    id=$(printf '%s' "$product" | tr '[:upper:]' '[:lower:]')
    added=0
    if game_ids | grep -qx "$id" || printf '%s\n' "$BUILTIN_GAMES" | cut -d'|' -f3 | grep -qx "$product"; then added=1; fi
    printf '%s|%s|%s\n' "$product" "$title" "$added"
  done
}

cmd_remove_game() { # id: forget a custom game and delete its files
  local id="$1" list
  case "$id" in dungeons|bedrock|'') echo "error|Built-in games can't be removed from the list; use Delete game files."; return 0 ;; esac
  select_game "$id" || { echo "error|unknown game"; return 0; }
  case "$STORE_DIR" in "$AS"/games/?*) rm -rf "$STORE_DIR" ;; esac
  conf_unset "custom_$id"; conf_unset "$EXE_KEY"
  list=$(conf_get custom_games "" | tr ',' '\n' | grep -vx "$id" | paste -sd, -)
  if [ -n "$list" ]; then conf_set custom_games "$list"; else conf_unset custom_games; fi
  echo "ok|removed"
}

cmd_delete_files() { # id: delete the downloaded files (saves live in the Windows layer, not here)
  select_game "$1" || { echo "error|unknown game"; return 0; }
  if game_running || pgrep -f "$XCLI run" >/dev/null 2>&1; then echo "error|Quit the game first."; return 0; fi
  case "$STORE_DIR" in "$AS"/games/?*) rm -rf "$STORE_DIR" ;; *) echo "error|unexpected folder"; return 0 ;; esac
  conf_unset "$EXE_KEY"
  echo "ok|Deleted the files of $GAME_NAME."
}

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

# --- per-game setup steps ---------------------------------------------------
# xcurl: Microsoft's XCurl.dll (the GDK's HTTP layer) never gets a request onto
# the wire under Wine, so a real Windows libcurl, which exports every curl_*
# function the game imports, takes its place (Ferestre's finding for Bedrock).
# Every download restores Microsoft's file, so this runs after each one.
setup_xcurl() {
  local dll tmp
  dll=$(find "$STORE_DIR" -maxdepth 2 -type f -iname 'xcurl.dll' 2>/dev/null | head -n 1)
  [ -n "$dll" ] || { log "xcurl: no XCurl.dll in $STORE_DIR"; return 0; }
  if [ ! -f "$AS/curl/libcurl-x64.dll" ]; then
    fetch_build dfm-curl.tar.gz "$DL/dfm-curl.tar.gz" "Downloading the network fix" 97 98 "$DFM_APPREL" || return 1
    tmp=$(mktemp -d "$AS/unpack.XXXXXX") || return 1
    tar -xzf "$DL/dfm-curl.tar.gz" -C "$tmp" && [ -f "$tmp/curl/libcurl-x64.dll" ] \
      || { rm -rf "$tmp"; fail "The network fix download looks incomplete."; return 1; }
    rm -rf "$AS/curl"; mv "$tmp/curl" "$AS/curl"; rm -rf "$tmp" "$DL/dfm-curl.tar.gz" "$DL/dfm-curl.tar.gz.expected"
  fi
  # keep Microsoft's original beside it (it carries the xcurl_* exports curl lacks)
  if grep -aq 'xcurl_' "$dll" 2>/dev/null; then cp -f "$dll" "$dll.microsoft"; fi
  cp -f "$AS/curl/libcurl-x64.dll" "$dll" || { fail "Couldn't install the network fix."; return 1; }
  [ -f "$AS/curl/curl-ca-bundle.crt" ] && cp -f "$AS/curl/curl-ca-bundle.crt" "$(dirname "$dll")/curl-ca-bundle.crt"
  log "xcurl: replaced $dll with libcurl"
}

run_game_setup() {
  local step
  for step in $(printf '%s' "$GAME_SETUP" | tr ',' ' '); do
    case "$step" in
      xcurl) setup_xcurl || return 1 ;;
    esac
  done
  return 0
}

# --- D3DMetal (DirectX 12) ---------------------------------------------------
# Apple's D3DMetal ships inside the Sikarugir runtime this app already downloads.
# It is Apple-licensed (Game Porting Toolkit licence: evaluation use, no
# redistribution or modification), so it is only used after the person accepts
# that licence in the app, and it is never modified.
D3DM="$FW/renderer/d3dmetal"
ensure_d3dmetal() {
  [ -d "$D3DM/wine" ] && [ -d "$D3DM/external" ] && return 0
  download "$RT_URL" "$DL/runtime.tar.xz" "$RT_SHA" "$RT_SIZE" "Downloading DirectX 12 support (D3DMetal)" 2 80 || return 1
  local tmp; tmp=$(mktemp -d "$AS/unpack.XXXXXX") || return 1
  progress -1 "Unpacking D3DMetal..."
  if ! tar -xJf "$DL/runtime.tar.xz" -C "$tmp" "$RT_SUBPATH/renderer/d3dmetal" >> "$LOGS/setup.log" 2>&1 \
     || [ ! -d "$tmp/$RT_SUBPATH/renderer/d3dmetal/wine" ]; then
    rm -rf "$tmp"; fail "Couldn't unpack D3DMetal."; return 1
  fi
  rm -rf "$D3DM"; mv "$tmp/$RT_SUBPATH/renderer/d3dmetal" "$D3DM"; rm -rf "$tmp" "$DL/runtime.tar.xz"
  log "d3dmetal installed"
}

cmd_d3dmetal_license() { # path of Apple's licence text, for the window to open
  local f
  for f in "$D3DM/License.rtf" "$D3DM/Read Me.rtf"; do [ -f "$f" ] && { echo "ok|$f"; return 0; }; done
  echo "none|https://developer.apple.com/games/game-porting-toolkit/"
}

job_storeinstall() { # [game id]
  select_game "${1:-dungeons}" || { fail "Unknown game."; return 1; }
  [ -x "$XCLI" ] || { fail "Run setup first."; return 1; }
  [ "$(conf_get signed_in 0)" = 1 ] || { fail "Sign in with your Microsoft account first."; return 1; }
  local gb; gb=$(free_gb "$AS")
  [ "${gb:-0}" -ge 10 ] || { fail "Downloading $GAME_NAME needs at least 10 GB free (this Mac has ${gb:-0} GB)."; return 1; }
  client_env
  mkdir -p "$STORE_DIR"
  progress 0 "Asking Microsoft for your copy of $GAME_NAME..."
  : > "$LOGS/store-download.log"
  ( XODUS_PROGRESS=json exec "$XCLI" streaming "$STORE_PRODUCT" "$STORE_DIR" ) > "$STATE/stream.out" 2>> "$LOGS/store-download.log" &
  local pid=$! line done_b total pct
  echo "$pid" > "$STATE/child.pid"
  while kill -0 "$pid" 2>/dev/null; do
    line=$(grep -o '"progress":{"done":[0-9]*,"total":[0-9]*' "$STATE/stream.out" 2>/dev/null | tail -n 1)
    done_b=$(printf '%s' "$line" | sed -n 's/.*"done":\([0-9]*\).*/\1/p')
    total=$(printf '%s' "$line" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      pct=$(( done_b * 96 / total ))
      progress "$pct" "Downloading $GAME_NAME from Microsoft - $(( done_b / 1048576 )) of $(( total / 1048576 )) MB"
    fi
    sleep 1
  done
  wait "$pid"; local rc=$?
  rm -f "$STATE/child.pid"
  # judge only the client's error output: progress lines hold byte counts ("…403…")
  local err; err=$(grep -v '"progress"' "$LOGS/store-download.log" 2>/dev/null)
  cat "$STATE/stream.out" >> "$LOGS/store-download.log" 2>/dev/null
  if [ $rc -ne 0 ] || [ ! -f "$STORE_DIR/.xodus-streaming.msixvc" ]; then
    local last; last=$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 3 | cut -c1-300)
    if printf '%s' "$err" | grep -qiE 'Device group is full'; then
      fail "Your Microsoft account has reached its limit of 10 devices for Store games, so Microsoft won't add this Mac.

Unlink old devices you no longer use (old PCs, Parallels or other virtual machines) at account.microsoft.com/devices/content, then press Download again."
    elif printf '%s' "$err" | grep -qiE 'not entitled to this content|SatisfactionFailure'; then
      fail "Microsoft says this account doesn't own $GAME_NAME. Sign in with the account that bought it.

Microsoft's answer: $last"
    elif printf '%s' "$err" | grep -qiE 'No \.msixvc file found'; then
      fail "$GAME_NAME isn't an Xbox PC (MSIXVC) game, so it can't run here yet.

$last"
    elif [ -n "$last" ]; then
      fail "The download didn't work (code $rc):

$last

Make a diagnostics report (More...) and send it over if this keeps happening."
    else
      fail "The download stopped (code $rc). Press Download again to resume."
    fi
    return 1
  fi
  local exe; exe=$(store_exe)
  [ -n "$exe" ] || { fail "Downloaded, but MicrosoftGame.config names no executable."; return 1; }
  run_game_setup || return 1
  if [ "$GAME_RENDERER" = d3dmetal ]; then ensure_d3dmetal || return 1; fi
  conf_set "$EXE_KEY" "$exe"
  [ "$GAME_ID" = dungeons ] && conf_set game_mode store
  progress 100 "Done"
  okmsg "$GAME_NAME is downloaded. Press Play!"
}

# PlayStation and Switch pads: Wine prefers handing Sony controllers to games as
# raw HID devices (for games with native DualShock/DualSense support) and drops
# the SDL-mapped XInput version. These games only understand XInput/GameInput
# pads, so turn that preference off per vendor: 054c Sony, 057e Nintendo.
PADS_MARK="$PREFIX/.dfm-pads-1"
apply_controller_settings() {
  [ -f "$PADS_MARK" ] && return 0
  local reg="$PREFIX/drive_c/dfm-pads.reg" rc
  {
    printf 'REGEDIT4\r\n\r\n'
    printf '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\054c]\r\n"Hidraw"=dword:00000000\r\n\r\n'
    printf '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\057e]\r\n"Hidraw"=dword:00000000\r\n\r\n'
    printf '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus]\r\n"Map Controllers"=dword:00000001\r\n"Enable SDL"=dword:00000001\r\n'
  } > "$reg"
  ( wine_env setup; "$WINE" reg import 'C:\dfm-pads.reg' ) >> "$LOGS/setup.log" 2>&1
  rc=$?
  rm -f "$reg"
  wait_server 30 || stop_server
  [ $rc -eq 0 ] && touch "$PADS_MARK"
  log "controller settings applied (rc $rc)"
}

# RAM disks the sign-in client left behind (a launch that was stopped before it
# could clean up). Only when no game is running.
detach_stale_ramdisks() {
  pgrep -f "$XCLI run" >/dev/null 2>&1 && return 0
  local d
  for d in $(hdiutil info 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ && /\/Volumes\/xodus-/ {print $1}'); do
    hdiutil detach -force "$d" >/dev/null 2>&1 && log "detached a leftover RAM disk ($d)"
  done
}

# Display mode. Unreal games (like Minecraft Dungeons) read -windowed and
# -fullscreen from their command line; other games use their own video setting.
# Only single "-switch" words: Unreal reads a bare word as the map to open, so a
# switch with a separate value (Unity's "-screen-fullscreen 1") stops it starting.
# Exclusive full screen also has the Mac driver capture the display.
display_args() {
  case "$(conf_get display game)" in
    windowed)             echo "-windowed" ;;
    fullscreen|exclusive) echo "-fullscreen" ;;
  esac
}

apply_display_settings() {
  local want mark="$PREFIX/.dfm-display" reg="$PREFIX/drive_c/dfm-display.reg" rc cap=n
  want=$(conf_get display game)
  [ "$want" = exclusive ] && cap=y
  [ "$(cat "$mark" 2>/dev/null)" = "$cap" ] && return 0
  printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n"CaptureDisplaysForFullscreen"="%s"\r\n' "$cap" > "$reg"
  ( wine_env setup; "$WINE" reg import 'C:\dfm-display.reg' ) >> "$LOGS/setup.log" 2>&1
  rc=$?
  rm -f "$reg"
  wait_server 30 || stop_server
  [ $rc -eq 0 ] && echo "$cap" > "$mark"
  log "display settings applied: $want (rc $rc)"
}

# Where a game looks for NVIDIA's DLSS library (nvngx.dll). Set only while
# "DLSS -> MetalFX" is on, so games don't offer DLSS otherwise.
apply_dlss_settings() {
  local want mark="$PREFIX/.dfm-dlss" reg="$PREFIX/drive_c/dfm-dlss.reg" rc
  want=$(conf_get metalfx 0)
  [ "$(cat "$mark" 2>/dev/null)" = "$want" ] && return 0
  {
    printf 'REGEDIT4\r\n\r\n'
    if [ "$want" = 1 ]; then
      printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore]\r\n"FullPath"="C:\\\\Windows\\\\System32"\r\n\r\n'
      printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global]\r\n"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=dword:00000001\r\n\r\n'
      printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm]\r\n"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=dword:00000001\r\n'
    else
      printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore]\r\n"FullPath"=-\r\n\r\n'
      printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global]\r\n"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=-\r\n\r\n'
      printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm]\r\n"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=-\r\n'
    fi
  } > "$reg"
  ( wine_env setup; "$WINE" reg import 'C:\dfm-dlss.reg' ) >> "$LOGS/setup.log" 2>&1
  rc=$?
  rm -f "$reg"
  wait_server 30 || stop_server
  [ $rc -eq 0 ] && echo "$want" > "$mark"
  log "DLSS settings applied: $want (rc $rc)"
}

play_store() {
  local exe glog
  exe=$(conf_get "$EXE_KEY" "")
  if [ "$GAME_RENDERER" = d3dmetal ]; then
    [ "$(conf_get d3dmetal_license 0)" = 1 ] || { echo "licence|$GAME_NAME needs Apple's D3DMetal, which needs you to accept Apple's licence first."; return 0; }
    [ -d "$D3DM/wine" ] || { echo "error|DirectX 12 support isn't installed yet. Choose Download again."; return 0; }
  fi
  start_service || { echo "error|The Xbox sign-in service didn't start in time. If macOS asked about the keychain, choose Always Allow, then press Play again."; return 0; }
  stop_server
  apply_controller_settings
  apply_dlss_settings
  apply_display_settings
  rotate_logs
  glog="$LOGS/game-$(date +%Y%m%d-%H%M%S).log"
  printf 'Dungeons for Mac %s (build %s) - %s, exe=%s\nrenderer=%s fps=%s upscale=%s dlss=%s sync=%s\n----\n' \
    "$DFM_VERSION" "$DFM_BUILD" "$GAME_NAME" "$exe" "$GAME_RENDERER" "$(conf_get fps 60)" "$(upscale_setting)" "$(conf_get metalfx 0)" "$(conf_get sync msync)" > "$glog"
  rm -f "$STATE/last_exit"
  mkdir -p "$AS/app"
  printf '#!/bin/bash\nexec /bin/bash %s __wine "$@"\n' "'$SELF'" > "$AS/app/wine-shim.sh" && chmod 755 "$AS/app/wine-shim.sh"
  cd "$STORE_DIR" || { echo "error|The game folder is missing."; return 0; }
  export DFM_GAME="$GAME_ID"
  detach_stale_ramdisks
  (
    # Not tied to the window that pressed Play: ignore hangup/terminate (the
    # game inherits that) and run in a process group of its own.
    trap '' HUP TERM
    set -m
    start=$(date +%s)
    echo "launch: asking Microsoft for the licence and decrypting the game..."
    # The client decrypts the game onto a RAM disk and starts "$SELF __wine",
    # which sets the graphics environment and execs this engine's wine.
    RUST_BACKTRACE=1 "$XCLI" run -e "$exe" "$STORE_DIR" "$AS/app/wine-shim.sh" &
    wait $!
    code=$?
    echo "launch: the sign-in client finished with code $code"
    echo "$code $(( $(date +%s) - start ))" > "$STATE/last_exit"
  ) >> "$glog" 2>&1 < /dev/null &
  log "play ($GAME_ID): $exe"
  echo "ok|Starting $GAME_NAME."
}

cmd_wine_shim() { # called by xodus-cli as its "wine": inherited fds stay open across exec
  select_game "${DFM_GAME:-dungeons}"
  GAME_RENDERER_FOR_LAUNCH="$GAME_RENDERER"
  wine_env game
  client_env
  export WINE_GAMEINPUT=1
  export WINEDEBUG="${DFM_WINEDEBUG:-fixme-all,warn+hid,warn+ginput,warn+xinput}"
  echo "launch: game decrypted, starting the Windows layer ($GAME_RENDERER graphics, display $(conf_get display game))" >&2
  # The client starts "wine <game.exe>"; display mode and extra launch options
  # go after it as the game's own command line.
  local extra=() a
  for a in $(display_args); do extra[${#extra[@]}]="$a"; done
  # shellcheck disable=SC2086
  for a in $(conf_get args ""); do extra[${#extra[@]}]="$a"; done
  if [ ${#extra[@]} -gt 0 ]; then exec "$WINE" "$@" "${extra[@]}"; fi
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

cmd_play() { # [game id]
  if [ ! -f "$READY_MARK" ] || [ ! -f "$PREFIX_MARK" ]; then echo "error|Setup hasn't finished yet."; return 0; fi
  local exe target args root glog
  if [ -n "$1" ] && [ "$1" != dungeons ]; then
    select_game "$1" || { echo "error|Unknown game."; return 0; }
    store_ready || { echo "error|$GAME_NAME isn't downloaded yet."; return 0; }
    if pgrep -f "$XCLI run" >/dev/null 2>&1; then echo "running|A game is already running."; return 0; fi
    if job_alive; then echo "error|Wait for the current task to finish first."; return 0; fi
    play_store
    return 0
  fi
  select_game dungeons
  if [ "$(conf_get game_mode launcher)" = store ] && store_ready; then
    if game_running || pgrep -f "$XCLI run" >/dev/null 2>&1; then echo "running|A game is already running."; return 0; fi
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
    echo; echo "== controllers macOS sees"
    if is_mac; then ioreg -r -c IOHIDDevice -l 2>/dev/null | grep -E '"Product"|"PrimaryUsagePage"|"Transport"' | sed -n '1,60p'; fi
    echo; echo "== processes (game, Windows layer, sign-in client)"
    ps -axo pid,ppid,stat,rss,etime,command 2>/dev/null | grep -iE 'xodus|wine|Dungeons|Minecraft|\.exe' | grep -v grep | cut -c1-220
    echo; echo "== RAM disks"; hdiutil info 2>/dev/null | grep -E 'image-path|/dev/disk|xodus' | head -40
    echo; echo "== memory"; vm_stat 2>/dev/null | head -12; memory_pressure -Q 2>/dev/null | tail -2
    echo; echo "== recent crash reports"
    ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -iE 'xodus|wine|Dungeons|Minecraft' | head -10
    echo; echo "== games"; cmd_games
    for g in $(game_ids); do
      select_game "$g" || continue
      [ -x "$XCLI" ] && [ -d "$STORE_DIR" ] || continue
      echo; echo "== $GAME_NAME: package identity"
      c=$(store_config); [ -n "$c" ] && tr -d '\r' < "$c" | grep -oiE '(TitleId|MSAAppId|StoreId|Identity Name|Executable Name)="?[^" >]*' | sort -u
      echo; echo "== $GAME_NAME: xbl-check (Xbox Live sign-in self-test; prints no tokens)"
      client_env
      "$XCLI" xbl-check "$STORE_DIR" 2>&1 | tail -n 40
    done
  } > "$dir/DungeonsForMac-diagnostics/summary.txt" 2>&1
  cp "$LOGS"/*.log "$dir/DungeonsForMac-diagnostics/" 2>/dev/null
  # game search: what Microsoft listed (product IDs and entitlement types) and what was read from it
  head -c 40000 "$STATE/library.json" > "$dir/DungeonsForMac-diagnostics/library-owned.json" 2>/dev/null
  cp "$LIBRARY_CACHE" "$dir/DungeonsForMac-diagnostics/library.txt" 2>/dev/null
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
  echo "upscale=$(upscale_setting)"
  echo "hud=$(conf_get hud 0)"
  echo "metalfx=$(conf_get metalfx 0)"
  echo "d3dmetal_license=$(conf_get d3dmetal_license 0)"
  echo "sync=$(conf_get sync msync)"
  echo "launch=$(conf_get launch direct)"
  echo "args=$(conf_get args "")"
  echo "display=$(conf_get display game)"
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
    sharp|hud|metalfx) case "$v" in 0|1) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    upscale)  case "$v" in off|1.5|2) ;; *) echo "error|bad value"; return 0 ;; esac; conf_unset sharp ;;
    sync)     case "$v" in msync|esync|off) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    launch)   case "$v" in direct|bootstrap) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    args)     ;;
    display)  case "$v" in game|windowed|fullscreen|exclusive) ;; *) echo "error|bad value"; return 0 ;; esac ;;
    *) echo "error|unknown setting"; return 0 ;;
  esac
  conf_set "$k" "$v"
  echo "ok|$k=$v"
}

cmd_reset_settings() {
  local k
  for k in renderer fps sharp upscale metalfx display hud sync launch args; do conf_unset "$k"; done
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
  play)           cmd_play "$1" ;;
  games)          cmd_games ;;
  add-game)       cmd_add_game "$1" "$2" ;;
  game-renderer)  cmd_game_renderer "$1" "$2" ;;
  library)        cmd_library "$1" "$2" ;;
  catalog)        mkdir -p "$STATE" "$LOGS"; library_js; printf '%s\n' "$@" | catalog_rows ;;
  remove-game)    cmd_remove_game "$1" ;;
  delete-files)   cmd_delete_files "$1" ;;
  d3dmetal-license) cmd_d3dmetal_license ;;
  accept-d3dmetal) conf_set d3dmetal_license 1; echo "ok|accepted" ;;
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
