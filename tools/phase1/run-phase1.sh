#!/bin/bash
#
# Phase 1 capture -- read the Drobo's ESA mode pages and save a log.
#
# Safe by design:
#   * droboprobe issues INQUIRY and MODE SENSE(10) only. It never writes.
#   * The volume is unmounted, not ejected. The device stays powered and
#     enumerated the whole time.
#   * Remount and daemon restart run from an EXIT trap, so they happen even
#     if the probe fails or you interrupt with Ctrl-C.
#
# Usage:
#   ./run-phase1.sh              # detect, confirm, capture
#   ./run-phase1.sh --dry-run    # show what it would do, touch nothing
#   ./run-phase1.sh --disk disk4 # skip autodetection
#
set -uo pipefail

DRY_RUN=0
FORCE_DISK=""
PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/droboprobe"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="drobo-phase1-${STAMP}.log"
DDPLIST="/Library/LaunchDaemons/com.datarobotics.ddservice64d.plist"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --disk)    FORCE_DISK="${2:-}"; shift 2 ;;
        --probe)   PROBE="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks

[ -x "$PROBE" ] || die "droboprobe not found or not executable at: $PROBE
    Build it with:  cd ../droboprobe && make
    or copy the prebuilt universal binary next to this script."

if ! "$PROBE" --help >/dev/null 2>&1; then
    die "droboprobe will not run here. If macOS quarantined it after a
    download or AirDrop, clear the flag:  xattr -d com.apple.quarantine '$PROBE'"
fi

# ---------------------------------------------------------------- find it

find_drobo_disk () {
    local d
    for d in $(diskutil list | awk '/^\/dev\/disk[0-9]+ \(external/ {gsub("/dev/","",$1); print $1}'); do
        if diskutil info "$d" 2>/dev/null | grep -qiE 'Device / Media Name:.*drobo'; then
            echo "$d"; return 0
        fi
    done
    return 1
}

if [ -n "$FORCE_DISK" ]; then
    DISK="$FORCE_DISK"
else
    DISK="$(find_drobo_disk)" || true
fi

if [ -z "${DISK:-}" ]; then
    warn "Could not autodetect a Drobo. External disks present:"
    diskutil list external | sed 's/^/    /'
    die "Re-run with:  $0 --disk diskN"
fi

say "Target device: /dev/$DISK"
diskutil info "$DISK" 2>/dev/null \
    | grep -E 'Device / Media Name|Volume Name|Disk Size|Protocol|Mounted' \
    | sed 's/^ */    /'

# ---------------------------------------------------------------- daemon

DAEMON_WAS_LOADED=0
if [ -f "$DDPLIST" ] && launchctl list 2>/dev/null | grep -q 'com.datarobotics.ddservice64d'; then
    DAEMON_WAS_LOADED=1
    warn "Drobo Dashboard's daemon (DDService64d) is running on this Mac."
    warn "It holds the device open, which will block exclusive access."
    warn "It will be stopped for the capture and restarted afterwards."
    warn "Quit the Drobo Dashboard app now if it is open."
fi

# ---------------------------------------------------------------- confirm

echo
say "Plan"
cat <<PLAN
    1. stop DDService64d                        $([ $DAEMON_WAS_LOADED -eq 1 ] && echo '(will run)' || echo '(not installed / not running)')
    2. diskutil unmountDisk /dev/$DISK          filesystem detaches, device stays up
    3. droboprobe --list and --dump             READ ONLY: INQUIRY + MODE SENSE(10)
    4. diskutil mountDisk /dev/$DISK            remount
    5. restart DDService64d                     $([ $DAEMON_WAS_LOADED -eq 1 ] && echo '(will run)' || echo '(skipped)')

    Log -> $(pwd)/$LOG
PLAN
echo

if [ $DRY_RUN -eq 1 ]; then
    say "Dry run: stopping here, nothing was touched."
    exit 0
fi

printf 'Proceed? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) die "Aborted. Nothing was touched." ;; esac

# ---------------------------------------------------------------- restore

RESTORED=0
restore () {
    [ $RESTORED -eq 1 ] && return
    RESTORED=1
    echo
    say "Restoring"
    diskutil mountDisk "/dev/$DISK" >/dev/null 2>&1 \
        && echo "    remounted /dev/$DISK" \
        || warn "remount failed -- do it by hand: diskutil mountDisk /dev/$DISK"
    if [ $DAEMON_WAS_LOADED -eq 1 ]; then
        sudo launchctl load "$DDPLIST" >/dev/null 2>&1 \
            && echo "    DDService64d restarted" \
            || warn "daemon restart failed: sudo launchctl load $DDPLIST"
    fi
    say "Log saved: $(pwd)/$LOG"
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------- capture

{
    echo "# Drobo Phase 1 capture -- $STAMP"
    echo "# host:  $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "# arch:  $(uname -m)"
    echo "# model: $(sysctl -n hw.model 2>/dev/null)"
    echo "# disk:  /dev/$DISK"
    echo
    echo "## diskutil info"
    diskutil info "$DISK" 2>&1
    echo
    echo "## ioreg: SCSI peripheral nubs"
    ioreg -c IOSCSIPeripheralDeviceNub -r -l 2>&1 | head -200
    echo
} > "$LOG" 2>&1

if [ $DAEMON_WAS_LOADED -eq 1 ]; then
    say "Stopping DDService64d"
    sudo launchctl unload "$DDPLIST" 2>&1 | tee -a "$LOG"
    sleep 2
fi

say "Unmounting /dev/$DISK"
if ! diskutil unmountDisk "/dev/$DISK" 2>&1 | tee -a "$LOG"; then
    die "unmount failed -- something is still using the volume.
    Close anything reading from the Drobo and try again."
fi

say "Probing (read-only)"
{
    echo
    echo "## droboprobe --list"
    sudo "$PROBE" --list 2>&1
    echo
    echo "## droboprobe --dump"
    sudo "$PROBE" --dump 2>&1
} | tee -a "$LOG"

# restore() runs from the EXIT trap
