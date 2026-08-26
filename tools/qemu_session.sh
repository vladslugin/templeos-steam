#!/usr/bin/env bash
#
# qemu_session.sh - start a guest plus the QMP driver, and wait until the driver
# is actually connected before returning.
#
# The QMP chardev accepts exactly one client. A leftover driver from a previous
# run keeps that slot and the next one hangs waiting for a greeting that never
# comes, so this tears both down first, every time.
#
# Usage:
#   bash tools/qemu_session.sh --install     # boot the ISO to install
#   bash tools/qemu_session.sh               # boot the installed disk
#   bash tools/qemu_session.sh --fresh       # wipe the disk, then install
#
# Then talk to the guest by appending actions to the queue:
#   echo 'shot build/shots/x.png'  >> build/mon_queue.txt
#   echo 'keys ret'                >> build/mon_queue.txt
#   echo "type 'Dir;' --enter"     >> build/mon_queue.txt
#   cat build/mon_out.txt
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$PATH:/c/Program Files/qemu"

PORT="${TEMPLE_QMP_PORT:-4444}"
QUEUE="build/mon_queue.txt"
OUT="build/mon_out.txt"
WIPE=0
WITH_SERIAL=0
PASS=()

for arg in "$@"; do
  case "$arg" in
    --fresh)  WIPE=1 ;;
    --serial) WITH_SERIAL=1 ;;
    *)        PASS+=("$arg") ;;
  esac
done

echo "stopping anything left over..."
taskkill //F //IM qemu-system-x86_64.exe >/dev/null 2>&1 || true
# Kill only our driver. Match on the command line, not the image name: each run
# shows up twice (the WindowsApps launcher plus the real interpreter) and killing
# by name alone leaves one of them holding the single QMP client slot, which then
# starves the next driver of its greeting.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" | Where-Object { \$_.CommandLine -like '*qemu_drive.py*' } | ForEach-Object { try { Stop-Process -Id \$_.ProcessId -Force -ErrorAction Stop } catch {} }" >/dev/null 2>&1 || true
sleep 2

mkdir -p build/shots
: > "$QUEUE"
rm -f "$OUT"

if [ "$WIPE" = "1" ]; then
  rm -f build/temple_disk.qcow2
  PASS+=(--install)
fi

echo "starting guest..."
# COM1 is opt-in, and when asked for it is a TCP socket rather than a named pipe.
# `-serial pipe:NAME` makes QEMU stall at start-up until something opens the other
# end, and a stalled QEMU never gets round to serving QMP either, so the whole
# guest looks hung. TCP with server,nowait has none of that.
SERIAL_PORT="${TEMPLE_COM1_PORT:-4555}"
SERIAL_ARGS=()
[ "$WITH_SERIAL" = "1" ] && SERIAL_ARGS=(--serial "$SERIAL_PORT")

nohup bash tools/run_qemu.sh "${PASS[@]}" --monitor "$PORT" "${SERIAL_ARGS[@]}" \
  > build/qemu_boot.log 2>&1 &

# Wait for the QMP port to start listening rather than sleeping a fixed guess.
for _ in $(seq 40); do
  if netstat -an 2>/dev/null | grep -q "127.0.0.1:$PORT .*LISTENING"; then break; fi
  sleep 0.5
done

echo "starting driver..."
nohup python tools/qemu_drive.py --port "$PORT" serve --queue "$QUEUE" --out "$OUT" \
  > build/mon_serve.log 2>&1 &

for _ in $(seq 60); do
  if [ -f "$OUT" ] && grep -q '^# connected' "$OUT" 2>/dev/null; then
    echo "driver connected."
    echo
    echo "queue : $QUEUE"
    echo "output: $OUT"
    [ "$WITH_SERIAL" = "1" ] && echo "COM1  : tcp 127.0.0.1:$SERIAL_PORT"
    exit 0
  fi
  sleep 0.5
done

echo "driver did not connect within 30s" >&2
echo "--- driver log ---" >&2
cat build/mon_serve.log >&2 || true
echo "--- guest log ---" >&2
tail -5 build/qemu_boot.log >&2 || true
exit 1
