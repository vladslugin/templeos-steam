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
VNC=""
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
  --vnc <port>         serve the framebuffer on 127.0.0.1:<port> so the launcher
                       can draw the guest inside its own window
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
    --vnc)      VNC="$2"; shift ;;
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
# Windows works too, and the note that used to be here saying it did not was
# wrong in an instructive way. WHPX aborted during boot with
#
#     decode->rex.rex
#
# an assertion in QEMU's own x86 decoder, and it did so with every CPU model
# tried - host, max, qemu64, Skylake-Client. So the CPU model was blamed. But
# the model was the only thing being varied: kernel_irqchip=off, taken from
# Terry's published script, was held constant across every attempt, and that is
# what was actually breaking it.
#
# With the interrupt controller left in the hypervisor partition, QEMU never
# has to decode the instruction that touches it. This QEMU build imports only
# WinHvPlatform.dll and no WinHvEmulation.dll, so every WHPX memory-mapped exit
# is decoded by QEMU's own emulator - the one that was asserting. Move the APIC
# into the partition and that whole class of exit stops happening.
#
# Measured on this guest: a 100-million-iteration HolyC loop takes 0.400s under
# TCG and 0.064s under WHPX. Six times faster, for one flag.
#
# kernel_irqchip is set explicitly rather than left to default, because WHPX's
# default is allowed-not-required: on a host without an in-partition APIC it
# would quietly fall back to the configuration that crashes, with the reason
# buried in a log file. Asking for it by name turns that into a clean refusal.
# It is inert under TCG, so one machine string serves both.
if [ "$ACCEL" = "auto" ]; then
  case "$HOST_OS" in
    linux)   [ -w /dev/kvm ] && ACCEL="kvm" || ACCEL="tcg" ;;
    windows) ACCEL="whpx" ;;
    macos)   ACCEL="hvf" ;;
    *)       ACCEL="tcg" ;;
  esac
fi

# The accelerator goes in the machine string as a list, so QEMU falls back on
# its own if the first one cannot start. Windows Hypervisor Platform is not
# installed everywhere - on this machine it is present only because WSL2
# brought VirtualMachinePlatform with it, and the Hyper-V feature proper reads
# Disabled - so a player without it must still get a working game, slowly,
# rather than a launcher that dies at startup.
CPU_ARGS=()
case "$ACCEL" in
  kvm)  ACCEL_LIST="kvm:tcg";  CPU_ARGS=(-cpu host) ;;
  hvf)  ACCEL_LIST="hvf:tcg";  CPU_ARGS=(-cpu host) ;;
  # Not -cpu host and not -cpu max. Both are fatal here in the worst way: QEMU
  # stays alive, logs "WHPX: Unexpected VP exit code 4", and the guest never
  # initialises its display - so the launcher would wait out its timeout on a
  # black window rather than report anything.
  whpx) ACCEL_LIST="whpx:tcg"; CPU_ARGS=(-cpu qemu64) ;;
  tcg)  ACCEL_LIST="tcg"
        CPU_ARGS=(-cpu qemu64)
        echo "note: hardware acceleration not requested; the guest will run" >&2
        echo "      about six times slower under emulation." >&2 ;;
  *)    echo "unknown --accel: $ACCEL" >&2; exit 2 ;;
esac

# Two cores unless asked otherwise, whatever the accelerator. Terry ran eight
# under KVM (emu8core) and that is right for a workstation, but this is a game
# and the guest has nothing to do with the other six.
#
# Under TCG more cores are actively harmful: emulation is serialised, so extra
# cores only add the guest's own cost of coordinating them. Measured at the
# desktop, four cores gave 13 FPS against two cores' 26. Under WHPX the count
# makes no measurable difference to boot at all - 1, 2, 4 and 8 all landed
# within 0.1s of each other - so there is nothing to buy by raising it, and
# each core is another host thread.
#
# Two rather than one, because the campaign has a task about running work on a
# second core and it needs one to exist.
if [ "$CORES_EXPLICIT" = "0" ]; then
  CORES=2
fi

# TempleOS has exactly one sound device: the PC speaker.
AUDIO_ARGS=()
MACHINE="pc,kernel_irqchip=on,accel=$ACCEL_LIST"
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

# Name the format rather than letting QEMU probe it. Probing works, but it then
# refuses writes to block 0 as a safety measure - and block 0 is the MBR, which
# is exactly what a boot-loader install has to touch.
case "$DISK" in
  *.qcow2) DISK_FMT="qcow2" ;;
  *)       DISK_FMT="raw" ;;
esac

CORES_WAS="$CORES"
ARGS=(
  -machine "$MACHINE"
  "${CPU_ARGS[@]}"
  -smp "cores=$CORES"
  -m "$MEM"
  -rtc base=localtime          # the OS reads the RTC as local time
  -drive "file=$DISK,format=$DISK_FMT,index=0,media=disk"
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
  # A bare number means TCP, and TCP is what you want while developing.
  #
  # `-serial pipe:NAME` on Windows blocks QEMU during start-up until something
  # opens the other end, and while it blocks it never gets round to serving QMP -
  # so the guest looks hung and the driver times out waiting for a greeting. TCP
  # has none of that and behaves the same on every host.
  #
  # QEMU is the client here, not the server, and that is the important part.
  # As a server its socket takes one client for the life of the guest: the
  # launcher connects, the player closes it, and every launcher after that gets
  # a refused connection with no way back short of restarting the emulator.
  # Reversed, the host listens and QEMU keeps knocking every second, so the
  # bridge comes back by itself whenever something is there to answer - after a
  # crash, after an alt-F4, after a developer kills the launcher for the tenth
  # time in an evening. It also means nothing has to be listening at boot.
  if [ "$SERIAL" -eq "$SERIAL" ] 2>/dev/null; then
    # The long form, not -serial tcp:... - they are not equivalent here. The
    # shorthand takes reconnect-ms without complaint and then exits anyway the
    # moment the peer goes away; declared as a chardev it reconnects, which is
    # the whole point.
    ARGS+=(-chardev "socket,id=com1,host=127.0.0.1,port=$SERIAL,reconnect-ms=1000")
    ARGS+=(-serial chardev:com1)
    echo "COM1 -> tcp 127.0.0.1:$SERIAL (guest dials out, retrying every second)"
  else
    case "$HOST_OS" in
      windows) ARGS+=(-serial "pipe:$SERIAL") ;;
      *)       ARGS+=(-chardev "socket,id=com1,path=$SERIAL,reconnect-ms=1000")
               ARGS+=(-serial chardev:com1) ;;
    esac
    echo "COM1 -> $SERIAL  (blocks until the other end is opened)"
  fi
fi

if [ -n "$VNC" ]; then
  # RFB display numbers, not TCP ports: :0 is 5900. The launcher is given a
  # port, so convert here and keep the arithmetic in one place.
  ARGS+=(-vnc "127.0.0.1:$((VNC - 5900))")
  echo "VNC -> 127.0.0.1:$VNC (display :$((VNC - 5900)))"
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
