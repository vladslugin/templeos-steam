#!/usr/bin/env bash
#
# run_qemu.sh - reproducible TempleOS 5.03 launch.
#
# The flags come from Terry's own scripts, published at
# https://templeos.org/Downloads/QEMU/ - not from third-party guides:
#
#   emu8core     normal use:
#     qemu-system-x86_64 -hda ~/qemu_disk.qcow2 -machine kernel_irqchip=off \
#       -smp cores=8 -enable-kvm -cpu host -m 6000 -rtc base=localtime -soundhw pcspk
#   emu_std      install from CD: same, plus -cdrom ... -boot d, with -smp cores=1 -m 2048
#   emu_install  qemu-img create -f qcow2 ~/qemu_disk.qcow2 3G
#
# One thing had to change. `-soundhw pcspk` was removed in QEMU 6.0 (2021); the
# modern spelling is `-machine pcspk-audiodev=snd0 -audiodev <driver>,id=snd0`.
# We sniff the QEMU version and pick. Without this there is simply no sound, and
# the PC speaker is the only audio device TempleOS has.
#
# Also brings up COM1 when asked, which is how the host bridge talks to the guest.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ISO="${TEMPLE_ISO:-$ROOT/vendor/iso/TempleOS.ISO}"
DISK="${TEMPLE_DISK:-$ROOT/build/temple_disk.qcow2}"
DISK_SIZE="${TEMPLE_DISK_SIZE:-3G}"       # Terry used 3G
CORES="${TEMPLE_CORES:-8}"
CORES_EXPLICIT=0
MEM="${TEMPLE_MEM:-2048}"                 # he ran 6000; 2048 is the documented minimum
MODE="run"
SERIAL=""
ACCEL="auto"
HEADLESS=0
MONITOR=""
EXTRA=()

usage() {
  cat <<'USAGE'
Usage: tools/run_qemu.sh [options] [-- <extra qemu flags>]

  --install            boot the ISO to install onto the disk (-boot d, 1 core, 2048 MB)
  --fresh              recreate the disk from scratch, then install
  --iso <path>         install media (default vendor/iso/TempleOS.ISO)
  --disk <path>        qcow2 disk (default build/temple_disk.qcow2)
  --cores <N>          core count (default 8)
  --mem <MB>           memory (default 2048)
  --serial <path>      expose COM1 for the host bridge:
                         Linux/macOS - unix socket at this path
                         Windows     - named pipe \\.\pipe\<name>
  --accel <type>       kvm | whpx | hvf | tcg | auto (default auto)
  --headless           no window (-display none), for CI
  --monitor <port>     QMP on 127.0.0.1:<port>, so tools/qemu_drive.py can type keys
                       and grab screenshots without a human at the keyboard
  -h, --help           this text

Environment: TEMPLE_ISO, TEMPLE_DISK, TEMPLE_CORES, TEMPLE_MEM, TEMPLE_DISK_SIZE.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install)  MODE="install" ;;
    --fresh)    MODE="fresh" ;;
    --iso)      ISO="$2"; shift ;;
    --disk)     DISK="$2"; shift ;;
    --cores)    CORES="$2"; CORES_EXPLICIT=1; shift ;;
    --mem)      MEM="$2"; shift ;;
    --serial)   SERIAL="$2"; shift ;;
    --accel)    ACCEL="$2"; shift ;;
    --headless) HEADLESS=1 ;;
    --monitor)  MONITOR="$2"; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; EXTRA=("$@"); break ;;
    *)          echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

QEMU="${QEMU_BIN:-qemu-system-x86_64}"
if ! command -v "$QEMU" >/dev/null 2>&1; then
  cat >&2 <<EOF
$QEMU not found.

  Windows : winget install SoftwareFreedomConservancy.QEMU
            then add C:\\Program Files\\qemu to PATH
  Ubuntu  : sudo apt install qemu-system-x86 qemu-utils
  macOS   : brew install qemu
EOF
  exit 1
fi

QEMU_VER="$("$QEMU" --version | head -1 | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
QEMU_MAJOR="${QEMU_VER%%.*}"
[ -n "$QEMU_MAJOR" ] || QEMU_MAJOR=0

case "$(uname -s)" in
  Linux*)                  HOST_OS="linux" ;;
  Darwin*)                 HOST_OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*)    HOST_OS="windows" ;;
  *)                       HOST_OS="unknown" ;;
esac

# Terry ran -enable-kvm -cpu host on Linux.
#
# Windows is the problem. WHPX is present and the Hyper-V platform is enabled,
# but QEMU 11.1.0 aborts on this guest during boot with
#
#     decode->rex.rex
#
# an assertion in the x86 decoder, and it does so with every CPU model tried
# (host, max, qemu64, Skylake-Client). TCG boots fine. So Windows defaults to
# TCG until a QEMU version is found that does not abort; pass --accel whpx
# explicitly to retest.
if [ "$ACCEL" = "auto" ]; then
  case "$HOST_OS" in
    linux)   [ -w /dev/kvm ] && ACCEL="kvm" || ACCEL="tcg" ;;
    windows) ACCEL="tcg" ;;
    macos)   ACCEL="hvf" ;;
    *)       ACCEL="tcg" ;;
  esac
fi

ACCEL_ARGS=()
CPU_ARGS=()
case "$ACCEL" in
  kvm)  ACCEL_ARGS=(-accel kvm);  CPU_ARGS=(-cpu host) ;;
  hvf)  ACCEL_ARGS=(-accel hvf);  CPU_ARGS=(-cpu host) ;;
  whpx) ACCEL_ARGS=(-accel whpx); CPU_ARGS=(-cpu max) ;;
  tcg)  ACCEL_ARGS=(-accel tcg)
        CPU_ARGS=(-cpu qemu64)
        echo "WARNING: no hardware acceleration, falling back to TCG." >&2
        echo "         Expect to miss the 29.97 FPS the window manager targets." >&2 ;;
  *)    echo "unknown --accel: $ACCEL" >&2; exit 2 ;;
esac

# TempleOS has exactly one sound device: the PC speaker.
AUDIO_ARGS=()
MACHINE="pc,kernel_irqchip=off"
if [ "$QEMU_MAJOR" -ge 6 ]; then
  case "$HOST_OS" in
    linux)   AUDIODEV="pa,id=snd0" ;;
    macos)   AUDIODEV="coreaudio,id=snd0" ;;
    windows) AUDIODEV="dsound,id=snd0" ;;
    *)       AUDIODEV="none,id=snd0" ;;
  esac
  AUDIO_ARGS=(-audiodev "$AUDIODEV")
  MACHINE="$MACHINE,pcspk-audiodev=snd0"
else
  AUDIO_ARGS=(-soundhw pcspk)
fi

mkdir -p "$(dirname "$DISK")"
if [ "$MODE" = "fresh" ]; then
  if [ -e "$DISK" ]; then
    echo "About to delete $DISK"
    read -r -p "Everything in the guest, including /Home, will be lost. Continue? [y/N] " ans
    [ "$ans" = "y" ] || { echo "cancelled"; exit 1; }
    rm -f "$DISK"
  fi
  MODE="install"
fi

if [ ! -e "$DISK" ]; then
  echo "Creating $DISK ($DISK_SIZE)"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
  [ "$MODE" = "run" ] && MODE="install"
fi

CORES_WAS="$CORES"
ARGS=(
  -machine "$MACHINE"
  "${ACCEL_ARGS[@]}"
  "${CPU_ARGS[@]}"
  -smp "cores=$CORES"
  -m "$MEM"
  -rtc base=localtime          # the OS reads the RTC as local time
  -hda "$DISK"
  "${AUDIO_ARGS[@]}"
)

if [ "$MODE" = "install" ]; then
  if [ ! -f "$ISO" ]; then
    cat >&2 <<EOF
ISO not found: $ISO

  mkdir -p "$ROOT/vendor/iso"
  curl -L -o "$ROOT/vendor/iso/TempleOS.ISO" https://templeos.org/Downloads/TempleOS.ISO
  md5sum "$ROOT/vendor/iso/TempleOS.ISO"   # expect 2facf5d7cfa08de4c47aede4a64cfb44

The published size is 17,350,656 bytes; checksums live at
https://templeos.org/Downloads/md5sums.txt
EOF
    exit 1
  fi
  # Terry installed with a single core (emu_std) and ran with eight (emu8core).
  # Honour an explicit --cores, otherwise drop to one for the install.
  if [ "$CORES_EXPLICIT" = "0" ] && [ "$CORES" != "1" ]; then
    CORES=1
    for i in "${!ARGS[@]}"; do
      [ "${ARGS[$i]}" = "cores=$CORES_WAS" ] && ARGS[$i]="cores=1"
    done
  fi
  ARGS+=(-cdrom "$ISO" -boot d)
  echo "Install mode: booting from CD with $CORES core(s)."
fi

if [ -n "$SERIAL" ]; then
  case "$HOST_OS" in
    windows) ARGS+=(-serial "pipe:$SERIAL") ;;
    *)       ARGS+=(-serial "unix:$SERIAL,server,nowait") ;;
  esac
  echo "COM1 -> $SERIAL"
fi

if [ -n "$MONITOR" ]; then
  # QMP rather than the human monitor: JSON request/response framing means the
  # driver never has to guess where a reply ends, and errors come back as errors
  # instead of as silence.
  ARGS+=(-qmp "tcp:127.0.0.1:$MONITOR,server,nowait")
  echo "QMP -> 127.0.0.1:$MONITOR"
fi

[ "$HEADLESS" = "1" ] && ARGS+=(-display none)
[ "${#EXTRA[@]}" -gt 0 ] && ARGS+=("${EXTRA[@]}")

echo "QEMU $QEMU_VER · accel: $ACCEL · host: $HOST_OS"
printf '%q ' "$QEMU" "${ARGS[@]}"; echo
exec "$QEMU" "${ARGS[@]}"
