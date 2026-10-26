#!/usr/bin/env bash
# Prepare the Steam version of Command: Modern Operations (app 1076160) to run
# on Linux through Proton. Safe to re-run: every step checks before acting.
#
# It never asks Steam to install the game. If the game is not installed yet,
# it sets up what it can and tells you to re-run once Steam has installed it.
set -euo pipefail

APPID=1076160

GE_TAG=GE-Proton11-7
GE_NAME=GE-Proton11-7-x86_64 # directory and internal tool name
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_TAG/$GE_NAME.tar.gz"
GE_SHA512=7db87e9787e20c35cbdac26018431d5794626b626e4067b050684e45a88cc2ca229d7d263519eafb2e168cde5bef57611065d159d3685aaec152ccb9abe3073f

# Newer WebView2 runtimes do not install under Wine; 109 does.
WV2_VERSION=109.0.1518.78
WV2_URL="https://github.com/aedancullen/webview2-evergreen-standalone-installer-archive/releases/download/$WV2_VERSION/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
WV2_SHA256=f2cc49863e221402d4664d9fa944a47f22543da2dcb363438c3e598789b9fd5b

# The game's UI asks for Segoe UI, which Proton maps to Times New Roman.
# Selawik is Microsoft's openly licensed, metric-compatible stand-in.
SELAWIK_URL=https://github.com/microsoft/Selawik/releases/download/1.01/Selawik_Release.zip
SELAWIK_SHA256=3f62c51e05e3b5a1e6241cf92a371f0be2ea1183aa87b30718bbd40832a8d423
SELAWIK_FONTS=(selawk.ttf selawkb.ttf selawkl.ttf selawksb.ttf selawksl.ttf)

WINETRICKS_VERBS=(dotnet48 d3dcompiler_47 fontsmooth=rgb)

# The game is per-monitor DPI aware but its toolbars break above 96 DPI. A
# small host exe runs it DPI-unaware instead, so Wine scales the whole window.
HOST_EXE=CommandDPI.exe
LAUNCH_OPTIONS="bash -c 'exec \"\${@/Launcher.exe/$HOST_EXE}\"' -- %command%"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cmo-setup"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --reset        Delete the game's Proton prefix and build it again.
                 The game directory (Scenarios, saves) is not touched.
  --scale N      Scale the game's UI by N (e.g. 1.5 or 2) by setting the
                 prefix DPI to 96*N. Without it the DPI is left as is.
  --stop-steam   Shut Steam down if it is running, so the
                 game's Steam settings can be updated.
  --steam-root   Path to the Steam directory (default: auto-detect).
  -h, --help     Show this help.
EOF
}

RESET=0
SCALE=
STOP_STEAM=0
STEAM_ROOT=
while (($#)); do
    case $1 in
    --reset) RESET=1 ;;
    --scale) SCALE=${2:?--scale needs a number}; shift ;;
    --stop-steam) STOP_STEAM=1 ;;
    --steam-root) STEAM_ROOT=${2:?--steam-root needs a path}; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -n $SCALE ]]; then
    [[ $SCALE =~ ^[0-9]+([.][0-9]+)?$ ]] || { usage >&2; exit 2; }
    DPI=$(awk -v s="$SCALE" 'BEGIN { printf "%d", 96 * s + 0.5 }')
    ((DPI >= 96 && DPI <= 480)) || { echo "--scale must be between 1 and 5" >&2; exit 2; }
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

steam_running() { pgrep -x steam >/dev/null; }
game_running() { pgrep -f 'Command - Modern Operations' >/dev/null; }

# Download $1 to $2 unless a copy with the expected checksum is already there.
fetch() {
    local url=$1 dest=$2 algo=$3 sum=$4
    if [[ -f $dest ]] && echo "$sum  $dest" | "${algo}sum" -c --status; then
        return
    fi
    mkdir -p "$(dirname "$dest")"
    curl -fL --progress-bar -o "$dest.part" "$url"
    echo "$sum  $dest.part" | "${algo}sum" -c --status ||
        { rm -f "$dest.part"; die "checksum mismatch for $url"; }
    mv "$dest.part" "$dest"
}

# --- Requirements -------------------------------------------------------------

log "Checking requirements"
missing=()
for cmd in awk cmp curl pgrep tar sha256sum sha512sum protontricks protontricks-launch; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
done
((${#missing[@]} == 0)) || die "missing commands: ${missing[*]} (install them with your package manager; protontricks must be the native or pipx version, not the Flatpak)"
# The vdf module comes with protontricks. A pipx install keeps it in its own
# environment, so try protontricks' interpreter as well as the system one.
PYTHON=
pt_python=$(awk 'NR == 1 && sub(/^#! */, "") { print ($1 ~ /\/env$/ ? $2 : $1) }' "$(command -v protontricks)")
for py in python3 "$pt_python"; do
    [[ -n $py ]] && "$py" -c 'import vdf' 2>/dev/null && { PYTHON=$py; break; }
done
[[ -n $PYTHON ]] || die "python module 'vdf' not found (it ships with protontricks)"
ok "all tools present"

if [[ -z $STEAM_ROOT ]]; then
    for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/debian-installation" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "$HOME/snap/steam/common/.local/share/Steam"; do
        [[ -f $d/config/config.vdf ]] && { STEAM_ROOT=$(realpath "$d"); break; }
    done
fi
[[ -n $STEAM_ROOT && -d $STEAM_ROOT ]] || die "Steam directory not found; start Steam once or pass --steam-root"
ok "Steam at $STEAM_ROOT"

# --- Proton -------------------------------------------------------------------

log "Installing $GE_NAME"
GE_DIR="$STEAM_ROOT/compatibilitytools.d/$GE_NAME"
if [[ -x $GE_DIR/proton && $(cut -d' ' -f2 "$GE_DIR/version" 2>/dev/null) == "$GE_TAG" ]]; then
    ok "already installed"
else
    fetch "$GE_URL" "$CACHE_DIR/$GE_NAME.tar.gz" sha512 "$GE_SHA512"
    mkdir -p "$STEAM_ROOT/compatibilitytools.d"
    tmp=$(mktemp -d "$STEAM_ROOT/compatibilitytools.d/.cmo-setup.XXXXXX")
    tar -xzf "$CACHE_DIR/$GE_NAME.tar.gz" -C "$tmp"
    rm -rf "$GE_DIR"
    mv "$tmp/$GE_NAME" "$GE_DIR"
    rmdir "$tmp"
    ok "installed to $GE_DIR"
fi

log "Configuring the game in Steam"
# Forces $GE_NAME for the game in config.vdf and sets its launch options so
# Steam starts $HOST_EXE. With "check" it only lists what would change. Lines
# starting with "!" are problems that were left alone.
steam_config() {
    "$PYTHON" - "$1" "$STEAM_ROOT" "$APPID" "$GE_NAME" "$LAUNCH_OPTIONS" <<'EOF'
import glob, os, shutil, sys, vdf

mode, root, appid, tool, launch = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as f:
        return vdf.load(f)

def save(path, data):
    if not os.path.exists(path + ".cmo-setup.bak"):
        shutil.copy2(path, path + ".cmo-setup.bak")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        vdf.dump(data, f, pretty=True)
    os.replace(path + ".tmp", path)

path = os.path.join(root, "config", "config.vdf")
cfg = load(path)
mapping = cfg["InstallConfigStore"]["Software"]["Valve"]["Steam"].setdefault("CompatToolMapping", {})
if mapping.get(appid, {}).get("name") != tool:
    print(f"compatibility tool -> {tool}")
    if mode == "apply":
        mapping[appid] = {"name": tool, "config": "", "priority": "250"}
        save(path, cfg)

for path in glob.glob(os.path.join(root, "userdata", "*", "config", "localconfig.vdf")):
    cfg = load(path)
    apps = cfg["UserLocalConfigStore"]["Software"]["Valve"]["Steam"].setdefault("apps", {})
    current = apps.get(appid, {}).get("LaunchOptions", "")
    user = path.split(os.sep)[-3]
    if current == launch:
        continue
    if current:
        print(f"! user {user} has its own launch options; set them to: {launch}")
        continue
    print(f"launch options for user {user} -> {launch}")
    if mode == "apply":
        apps.setdefault(appid, {})["LaunchOptions"] = launch
        save(path, cfg)
EOF
}

report=$(steam_config check)
changes=$(grep -v '^!' <<<"$report" || true)
while IFS= read -r line; do [[ -n $line ]] && warn "${line#! }"; done < <(grep '^!' <<<"$report" || true)
if [[ -z $changes ]]; then
    ok "already configured"
else
    if steam_running && ((STOP_STEAM)); then
        log "Shutting Steam down"
        if command -v steam >/dev/null; then
            steam -shutdown >/dev/null 2>&1 || true
        elif command -v flatpak >/dev/null; then
            flatpak run com.valvesoftware.Steam -shutdown >/dev/null 2>&1 || true
        fi
        for _ in $(seq 60); do steam_running || break; sleep 1; done
        steam_running && die "Steam did not exit"
    fi
    if steam_running; then
        # Steam rewrites its config on exit, so editing it now would be lost.
        warn "Steam is running, so its config was left alone. Re-run with --stop-steam,"
        warn "or change these in the game's Properties by hand:"
        while IFS= read -r line; do warn "  $line"; done <<<"$changes"
    else
        steam_config apply >/dev/null
        while IFS= read -r line; do ok "$line"; done <<<"$changes"
        ok "originals backed up as *.cmo-setup.bak"
    fi
fi

# --- Game ---------------------------------------------------------------------

log "Looking for the installed game"
LIBRARY=$("$PYTHON" - "$STEAM_ROOT" "$APPID" <<'EOF'
import os, sys, vdf
root, appid = sys.argv[1:]
paths = [root]
try:
    lf = vdf.load(open(os.path.join(root, "steamapps", "libraryfolders.vdf"), encoding="utf-8"))
    paths += [v["path"] for v in lf.get("libraryfolders", {}).values() if isinstance(v, dict) and "path" in v]
except FileNotFoundError:
    pass
for p in paths:
    acf = os.path.join(p, "steamapps", f"appmanifest_{appid}.acf")
    if os.path.isfile(acf):
        state = vdf.load(open(acf, encoding="utf-8"))["AppState"]
        # StateFlags 4 = fully installed
        if int(state.get("StateFlags", 0)) & 4:
            print(p)
            break
EOF
)
if [[ -z $LIBRARY ]]; then
    warn "Command: Modern Operations is not installed (or not finished installing)."
    warn "Install it from Steam, then run this script again to finish the setup."
    exit 0
fi
GAME_DIR="$LIBRARY/steamapps/common/Command - Modern Operations"
COMPAT="$LIBRARY/steamapps/compatdata/$APPID"
PFX="$COMPAT/pfx"
ok "found in $LIBRARY"

game_running && die "the game is running; close it first"

# --- Prefix -------------------------------------------------------------------

if ((RESET)) && [[ -e $COMPAT ]]; then
    log "Deleting the existing prefix"
    rm -rf "$COMPAT"
    ok "deleted $COMPAT"
fi

log "Preparing the Proton prefix"
if [[ -f $COMPAT/version && -f $PFX/system.reg ]]; then
    made_by=$(head -n1 "$COMPAT/config_info" 2>/dev/null || true)
    if [[ $made_by != "$GE_TAG" ]]; then
        warn "the prefix was made by '${made_by:-unknown}', not $GE_TAG; re-run with --reset for a clean one"
    fi
    ok "prefix exists"
else
    mkdir -p "$COMPAT"
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" STEAM_COMPAT_DATA_PATH="$COMPAT" \
        SteamAppId=$APPID SteamGameId=$APPID PROTONFIXES_DISABLE=1 \
        "$GE_DIR/proton" run wineboot -u >/dev/null 2>&1
    [[ -f $PFX/system.reg ]] || die "Proton failed to create the prefix at $PFX"
    ok "created $PFX"
fi

# protontricks would otherwise use the tool Steam has selected, which may not
# be set yet if Steam was running.
export PROTON_VERSION=$GE_NAME STEAM_DIR=$STEAM_ROOT

log "Running winetricks (${WINETRICKS_VERBS[*]})"
for verb in "${WINETRICKS_VERBS[@]}"; do
    if grep -qx "$verb" "$PFX/winetricks.log" 2>/dev/null; then
        ok "$verb already installed"
    else
        # Proton symlinks its builtin DLLs into the prefix, pointing at its own
        # read-only files. The .NET 4.0 installer (pulled in by dotnet48)
        # overwrites some of them (dxva2.dll, evr.dll) and fails with "Failed
        # to extract cabinet". Writable copies fix that; Proton still treats
        # them as builtins and re-links them on its next upgrade.
        find "$PFX/drive_c/windows" -type l -lname '*/lib/wine/*' -print0 |
            while IFS= read -r -d '' link; do
                target=$(readlink -f "$link") && [[ -f $target ]] || continue
                rm -f "$link"
                cp "$target" "$link"
                chmod u+w "$link"
            done
        protontricks "$APPID" -q "$verb"
        grep -qx "$verb" "$PFX/winetricks.log" || die "winetricks did not install $verb"
        ok "$verb installed"
    fi
done

log "Installing WebView2 runtime $WV2_VERSION (needed for briefings and scenario text)"
WV2_DIR="$PFX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/$WV2_VERSION"
if [[ -f $WV2_DIR/msedgewebview2.exe ]]; then
    ok "already installed"
else
    fetch "$WV2_URL" "$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64-$WV2_VERSION.exe" sha256 "$WV2_SHA256"
    protontricks-launch --appid "$APPID" \
        "$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64-$WV2_VERSION.exe" /silent /install
    [[ -f $WV2_DIR/msedgewebview2.exe ]] || die "WebView2 did not install into $WV2_DIR"
    ok "installed"
fi

log "Installing the Selawik font (stand-in for Segoe UI)"
FONTS_DIR="$PFX/drive_c/windows/Fonts"
missing_fonts=()
for font in "${SELAWIK_FONTS[@]}"; do
    [[ -f $FONTS_DIR/$font ]] || missing_fonts+=("$font")
done
if ((${#missing_fonts[@]} == 0)); then
    ok "already installed"
else
    fetch "$SELAWIK_URL" "$CACHE_DIR/Selawik_Release.zip" sha256 "$SELAWIK_SHA256"
    "$PYTHON" - "$CACHE_DIR/Selawik_Release.zip" "$FONTS_DIR" "${missing_fonts[@]}" <<'EOF'
import os, sys, zipfile
archive, dest, *names = sys.argv[1:]
with zipfile.ZipFile(archive) as z:
    for name in names:
        with z.open(name) as src, open(os.path.join(dest, name), "wb") as dst:
            dst.write(src.read())
EOF
    ok "installed ${missing_fonts[*]}"
fi

log "Installing $HOST_EXE (runs the game DPI-unaware so it can be scaled)"
HOST_SRC=$(cat <<'EOF'
using System;
using System.IO;
using System.Runtime.InteropServices;

// Runs Command.exe inside a DPI-unaware process, so Wine scales the whole UI.
static class Host
{
    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [STAThread]
    static int Main(string[] args)
    {
        // DPI_AWARENESS_CONTEXT_UNAWARE; once set, the game's own call fails.
        SetProcessDpiAwarenessContext(new IntPtr(-1));

        string dir = AppDomain.CurrentDomain.BaseDirectory;
        var setup = new AppDomainSetup
        {
            ApplicationBase = dir,
            ConfigurationFile = Path.Combine(dir, "Command.exe.config"),
        };
        AppDomain domain = AppDomain.CreateDomain("Command", null, setup);
        return domain.ExecuteAssembly(Path.Combine(dir, "Command.exe"), args);
    }
}
EOF
)
# The game is obfuscated and checks itself for tampering, so it is hosted
# rather than patched. The host is built with the prefix's own C# compiler.
HOST_BUILD="$CACHE_DIR/host"
mkdir -p "$HOST_BUILD"
if [[ -f $HOST_BUILD/$HOST_EXE && $(cat "$HOST_BUILD/host.cs" 2>/dev/null) == "$HOST_SRC" ]]; then
    ok "already built"
else
    printf '%s\n' "$HOST_SRC" >"$HOST_BUILD/host.cs"
    rm -f "$HOST_BUILD/$HOST_EXE"
    (cd "$HOST_BUILD" && protontricks -c \
        "wine 'C:\\windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe' /nologo /target:winexe /platform:x64 /out:$HOST_EXE host.cs" \
        "$APPID" >/dev/null 2>&1) || true
    [[ -f $HOST_BUILD/$HOST_EXE ]] || die "failed to build $HOST_EXE"
    ok "built"
fi
if cmp -s "$HOST_BUILD/$HOST_EXE" "$GAME_DIR/$HOST_EXE"; then
    ok "already in the game directory"
else
    cp "$HOST_BUILD/$HOST_EXE" "$GAME_DIR/$HOST_EXE"
    ok "copied to the game directory"
fi

log "Writing registry settings"
# The game reports Windows 10; WebView2 only renders when it thinks it is on
# Windows 7. Steam runs the game's bundled (newer) WebView2 installer on first
# launch unless its "has run" marker is set; that installer fails under Wine.
# Segoe UI and its weights are pointed at the matching Selawik fonts.
protontricks -c "
    wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements' /v 'Segoe UI' /d 'Selawik' /f &&
    wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements' /v 'Segoe UI Semibold' /d 'Selawik Semibold' /f &&
    wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements' /v 'Segoe UI Light' /d 'Selawik Light' /f &&
    wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements' /v 'Segoe UI Semilight' /d 'Selawik Semilight' /f &&
    wine reg add 'HKCU\\Software\\Wine' /v Version /d win10 /f &&
    wine reg add 'HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe' /v Version /d win7 /f &&
    wine reg add 'HKLM\\Software\\Valve\\Steam\\Apps\\$APPID' /v WebView2 /t REG_DWORD /d 1 /f &&
    wine reg add 'HKLM\\Software\\WOW6432Node\\Valve\\Steam\\Apps\\$APPID' /v WebView2 /t REG_DWORD /d 1 /f ${DPI:+&&
    wine reg add 'HKCU\\Control Panel\\Desktop' /v LogPixels /t REG_DWORD /d $DPI /f}
" "$APPID" >/dev/null 2>&1 || die "failed to write registry settings"
ok "done${DPI:+ (UI scale $SCALE, $DPI DPI)}"

log "Setup complete"
echo "Launch Command: Modern Operations from Steam."
