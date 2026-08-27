#!/usr/bin/env bash
#
# run_launcher.sh - start the guest and the launcher, in one command.
#
# There is a fair amount to get right before the launcher has anything to show:
# QEMU needs a VNC display for the screen, a serial port for the bridge and a
# QMP socket so the boot menu can be answered, the guest needs about a minute to
# come up under emulation, and Godot is not on PATH on a normal install. None of
# that is interesting, so it lives here.
#
#   bash tools/run_launcher.sh                  open the launcher in a window
#   bash tools/run_launcher.sh --check hc_fib   run one task check and report
#   bash tools/run_launcher.sh --attach         a guest is already running
#
# Set GODOT to point at the binary if it is somewhere unusual.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$PATH:/c/Program Files/qemu"

DISK="${TEMPLE_DISK:-build/temple_disk.raw}"
VNC_PORT="${TEMPLE_VNC_PORT:-5909}"
COM_PORT="${TEMPLE_COM1_PORT:-4555}"
BRIDGE_PORT="${TEMPLE_BRIDGE_PORT:-4556}"
QMP_PORT="${TEMPLE_QMP_PORT:-4444}"
BOOT_TIMEOUT="${TEMPLE_BOOT_TIMEOUT:-180}"

ATTACH=0
HEADLESS=0
CHECK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --attach)   ATTACH=1 ;;
    --headless) HEADLESS=1 ;;
    --check)    CHECK="$2"; HEADLESS=1; shift ;;
    --disk)     DISK="$2"; shift ;;
    -h|--help)
      sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- find Godot
find_godot() {
  if [ -n "${GODOT:-}" ] && [ -x "$GODOT" ]; then echo "$GODOT"; return; fi
  for c in godot godot4 Godot; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return; fi
  done
  # A normal Windows install puts it here. Prefer the console build: the plain
  # one detaches from the terminal and prints nowhere.
  local d="$LOCALAPPDATA/Programs/Godot"
  [ -d "$d" ] || d="$HOME/AppData/Local/Programs/Godot"
  if [ -d "$d" ]; then
    local best
    best="$(ls -1 "$d"/Godot_v*_console.exe 2>/dev/null | grep -v mono | tail -1 || true)"
    [ -z "$best" ] && best="$(ls -1 "$d"/Godot_v*.exe 2>/dev/null | grep -v mono | grep -v console | tail -1 || true)"
    [ -z "$best" ] && best="$(ls -1 "$d"/godot.exe 2>/dev/null | tail -1 || true)"
    if [ -n "$best" ]; then echo "$best"; return; fi
  fi
  return 1
}

GODOT_BIN="$(find_godot || true)"
if [ -z "$GODOT_BIN" ]; then
  cat >&2 <<'EOF'
Godot was not found.

Point GODOT at it, for example:

  GODOT="$LOCALAPPDATA/Programs/Godot/Godot_v4.7.1-stable_win64_console.exe" \
      bash tools/run_launcher.sh

or install it: winget install GodotEngine.GodotEngine
EOF
  exit 1
fi
echo "Godot   : $GODOT_BIN"

if [ ! -f "$DISK" ]; then
  echo "No disk image at $DISK" >&2
  echo "Install one first:  bash tools/run_qemu.sh --install --disk $DISK" >&2
  exit 1
fi

# --------------------------------------------------------------- the guest
kill_stale() {
  taskkill //F //IM qemu-system-x86_64.exe >/dev/null 2>&1 || true
  # A launcher left over from a previous run holds the bridge port, and the
  # symptom looks nothing like the cause: the new run just cannot bind. Matched
  # on the project path, so an editor open on something else is left alone.
  powershell -NoProfile -Command     "Get-CimInstance Win32_Process -Filter \"Name like '%Godot%'\" | Where-Object { \$_.CommandLine -like '*host*temple*' } | ForEach-Object { try { Stop-Process -Id \$_.ProcessId -Force -ErrorAction Stop } catch {} }"     >/dev/null 2>&1 || true
  powershell -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" | Where-Object { \$_.CommandLine -like '*qemu_drive*' -or $_.CommandLine -like '*combridge*' } | ForEach-Object { try { Stop-Process -Id \$_.ProcessId -Force -ErrorAction Stop } catch {} }" \
    >/dev/null 2>&1 || true
  sleep 2
}

if [ "$ATTACH" = "0" ]; then
  kill_stale
  mkdir -p build

  # The guest dials out, and the emulator exits if a connection attempt is
  # refused - the first or any later one. So something has to hold that port
  # for the whole session while launchers come and go, and that is combridge:
  # it takes the guest's connection on one port and re-serves the conversation
  # on another, which is the one everything else talks to.
  rm -f build/bridge_ready.txt
  nohup python tools/combridge.py --guest-port "$COM_PORT" \
      --client-port "$BRIDGE_PORT" --ready-file build/bridge_ready.txt \
      > build/combridge.log 2>&1 &
  for _ in $(seq 100); do
    [ -f build/bridge_ready.txt ] && break
    sleep 0.1
  done
  if [ ! -f build/bridge_ready.txt ]; then
    echo "could not open the bridge ports; see build/combridge.log" >&2
    exit 1
  fi

  echo "Guest   : starting"
  nohup bash tools/run_qemu.sh --disk "$DISK" --headless \
      --monitor "$QMP_PORT" --serial "$COM_PORT" --vnc "$VNC_PORT" \
      > build/launcher_qemu.log 2>&1 &

  for _ in $(seq 60); do
    netstat -an 2>/dev/null | grep -q "127.0.0.1:$QMP_PORT .*LISTENING" && break
    sleep 0.5
  done

  : > build/mon_queue.txt
  rm -f build/mon_out.txt
  # --queue and --out belong to the serve subcommand and have to follow it.
  nohup python tools/qemu_drive.py --port "$QMP_PORT" serve \
      --queue build/mon_queue.txt --out build/mon_out.txt \
      > build/launcher_drive.log 2>&1 &
  sleep 3

  # Two prompts stand between power-on and a usable desktop, and a player should
  # see neither. The boot menu is a factory-image problem still to be solved;
  # the tour is a first-run question. Both are answered here for now.
  #
  # The menu appears at once and is answered on a short timer. Everything after
  # it waits on the guest rather than on a clock: the game layer runs last in
  # start-up and speaks as soon as it does, so that line is the boot finishing.
  # A flat ninety-five second sleep became about eight.
  { echo "sleep 3"; echo "keys 1"; } >> build/mon_queue.txt

  if BOOTED="$(python tools/wait_guest.py --port "$BRIDGE_PORT" --timeout "$BOOT_TIMEOUT")"; then
    echo "Guest   : desktop up in ${BOOTED}s"
  else
    echo "Guest   : no word from the layer after ${BOOT_TIMEOUT}s; going on anyway" >&2
  fi

  # StartUpTasks hands the tour prompt to a user terminal through XTalk, so it
  # can arrive a moment after the layer is already talking.
  { echo "sleep 2"; echo "keys n"; echo "sleep 2"; } >> build/mon_queue.txt
  sleep 6
else
  echo "Guest   : attaching to one already running"
fi

# ------------------------------------------------------------- the launcher
"$GODOT_BIN" --headless --path host/temple --import >/dev/null 2>&1 || true

ARGS=(--path host/temple)
[ "$HEADLESS" = "1" ] && ARGS+=(--headless)
ARGS+=(--)
ARGS+=(--bridge-port "$BRIDGE_PORT" --vnc-port "$VNC_PORT")
[ -n "$CHECK" ] && ARGS+=(--check "$CHECK")

echo "Launcher: starting"
echo
exec "$GODOT_BIN" "${ARGS[@]}"
