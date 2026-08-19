#!/bin/bash
#
# ESA capture runbook, to be run on the Mac that still has Drobo Dashboard.
#
# What it does, in order: checks the kext is loaded, stops DDService64d so it
# lets go of the device, runs droboesa (read-only), then restarts the daemon
# from an EXIT trap so it comes back even if something fails or you hit Ctrl-C.
#
# The volume is never unmounted and nothing is written to the enclosure.
# droboesa can only issue kext selectors 0, 1 and 2; the selector that writes
# settings is not reachable from it.
#
# NOTE: the daemon is detected with pgrep, not with `launchctl list`. Without
# sudo, launchctl only reports the user domain, so a system daemon like
# DDService64d never shows up there. That mistake cost us the first run: the
# daemon kept the device and sOpen came back kIOReturnExclusiveAccess.
#
# Usage:
#   ./run-esa-capture.sh            # check, confirm, capture
#   ./run-esa-capture.sh --dry-run  # show the plan, touch nothing
#
set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/droboesa"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HERE/drobo-esa-${STAMP}.log"
DDPLIST="/Library/LaunchDaemons/com.datarobotics.ddservice64d.plist"
DDLABEL="com.datarobotics.ddservice64d"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

daemon_running () { pgrep -x DDService64d >/dev/null 2>&1; }
dashboard_running () { pgrep -f "Drobo Dashboard.app" >/dev/null 2>&1; }

# ---------------------------------------------------------------- checks

[ -x "$TOOL" ] || die "droboesa not found at $TOOL
    Build it with 'make', or copy the prebuilt universal binary here."

if ! "$TOOL" --help >/dev/null 2>&1; then
    die "droboesa will not run. If it was quarantined after a transfer:
    xattr -dr com.apple.quarantine '$HERE'"
fi

# The kext has to actually be loaded, otherwise there is nothing to talk to.
if (kextstat 2>/dev/null || kmutil showloaded 2>/dev/null) | grep -q 'TrustedData'; then
    say "TrustedDataSCSIDriver is loaded"
else
    warn "TrustedDataSCSIDriver does not look loaded on this Mac."
    warn "This script only works where Drobo Dashboard is installed and working."
fi

DAEMON_PRESENT=0
daemon_running && DAEMON_PRESENT=1
[ -f "$DDPLIST" ] && DAEMON_PRESENT=1

if daemon_running; then
    say "DDService64d is running (pid $(pgrep -x DDService64d | tr '\n' ' '))"
else
    warn "DDService64d does not appear to be running."
fi

dashboard_running && warn "The Drobo Dashboard app is open. Quit it before continuing."

# ---------------------------------------------------------------- plan

echo
say "Plan"
cat <<PLAN
    0. you quit the Drobo Dashboard app, if it is open
    1. stop DDService64d and wait for it to exit   $([ $DAEMON_PRESENT -eq 1 ] && echo '(will run)' || echo '(nothing to stop)')
    2. droboesa --dump                             READ ONLY, kext selectors 0/1/2 only
    3. restart DDService64d                        $([ $DAEMON_PRESENT -eq 1 ] && echo '(will run)' || echo '(skipped)')

    The volume stays mounted throughout. Nothing is written to the Drobo.

    Log -> $LOG
PLAN
echo

if [ $DRY_RUN -eq 1 ]; then
    say "Dry run: stopping here, nothing was touched."
    exit 0
fi

cat <<'NOTE'
Before continuing, make sure you have noted what Dashboard currently shows
on the Status and Capacity screens. Those numbers are what let us match the
bytes to fields afterwards.
NOTE
echo
printf 'Dashboard quit, numbers noted, ready to go? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) die "Aborted. Nothing was touched." ;; esac

# ---------------------------------------------------------------- restore

RESTORED=0
restore () {
    [ $RESTORED -eq 1 ] && return
    RESTORED=1
    echo
    if [ $DAEMON_PRESENT -eq 1 ] && ! daemon_running; then
        say "Restarting DDService64d"
        sudo launchctl load "$DDPLIST" >/dev/null 2>&1 \
            || sudo launchctl bootstrap system "$DDPLIST" >/dev/null 2>&1
        for _ in $(seq 1 10); do
            daemon_running && break
            sleep 1
        done
        if daemon_running; then
            echo "    back up (pid $(pgrep -x DDService64d | tr '\n' ' '))"
        else
            warn "daemon did not come back. Start it by hand:"
            warn "  sudo launchctl load $DDPLIST"
        fi
    fi
    say "Log saved: $LOG"
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------- capture

{
    echo "# Drobo ESA capture -- $STAMP"
    echo "# host:  $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "# arch:  $(uname -m)"
    echo "# model: $(sysctl -n hw.model 2>/dev/null)"
    echo
    echo "## loaded Drobo kexts"
    (kextstat 2>/dev/null || kmutil showloaded 2>/dev/null) | grep -i 'drobo\|trusted'
    echo
    echo "## diskutil list external"
    diskutil list external 2>&1
    echo
} > "$LOG" 2>&1

# Stop the daemon and actually confirm it is gone before going further.
if [ $DAEMON_PRESENT -eq 1 ]; then
    say "Stopping DDService64d"
    sudo launchctl unload "$DDPLIST" 2>&1 | tee -a "$LOG"

    # KeepAlive is true in its plist, so give launchd a moment to give up.
    for _ in $(seq 1 15); do
        daemon_running || break
        sleep 1
    done

    # Fall back to the modern spelling if the old one did not take.
    if daemon_running; then
        warn "still running, trying launchctl bootout"
        sudo launchctl bootout "system/$DDLABEL" 2>&1 | tee -a "$LOG"
        for _ in $(seq 1 10); do
            daemon_running || break
            sleep 1
        done
    fi

    if daemon_running; then
        die "DDService64d will not stop, so it still owns the device.
    sOpen would fail with kIOReturnExclusiveAccess again.
    Quit Drobo Dashboard, then try by hand:
      sudo launchctl bootout system/$DDLABEL"
    fi
    say "DDService64d stopped, device released"
    echo "# daemon stopped OK" >> "$LOG"
fi

say "Reading ESA records (read-only)"
{
    echo
    echo "## droboesa --dump"
    sudo "$TOOL" --dump 2>&1
} | tee -a "$LOG"

# restore() runs from the EXIT trap
