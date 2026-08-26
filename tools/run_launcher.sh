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
QMP_PORT="${TEMPLE_QMP_PORT:-4444}"
BOOT_WAIT="${TEMPLE_BOOT_WAIT:-95}"

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
  powershell -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" | Where-Object { \$_.CommandLine -like '*qemu_drive*' } | ForEach-Object { try { Stop-Process -Id \$_.ProcessId -Force -ErrorAction Stop } catch {} }" \
    >/dev/null 2>&1 || true
  sleep 2
}

if [ "$ATTACH" = "0" ]; then
  kill_stale
  mkdir -p build
  echo "Guest   : starting (about ${BOOT_WAIT}s under emulation)"
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
  sleep 4

  # Two prompts stand between power-on and a usable desktop, and a player should
  # see neither. The boot menu is a factory-image problem still to be solved;
  # the tour is a first-run question. Both are answered here for now.
  printf 'sleep 6\nkeys 1\nsleep %d\nkeys n\nsleep 4\n' "$((BOOT_WAIT - 15))" >> build/mon_queue.txt
  sleep "$BOOT_WAIT"
else
  echo "Guest   : attaching to one already running"
fi

# ------------------------------------------------------------- the launcher
"$GODOT_BIN" --headless --path host/temple --import >/dev/null 2>&1 || true

ARGS=(--path host/temple)
[ "$HEADLESS" = "1" ] && ARGS+=(--headless)
ARGS+=(--)
[ -n "$CHECK" ] && ARGS+=(--check "$CHECK")

echo "Launcher: starting"
echo
exec "$GODOT_BIN" "${ARGS[@]}"
