#!/bin/bash
#
# check-dext.sh -- run this on the test Mac before and after activating the
# driver. Self contained on purpose: it does not need the repo, just scp this
# one file across.
#
#   ./check-dext.sh          state of the machine and the driver
#   ./check-dext.sh --logs   the above plus the recent activation logs
#
set -uo pipefail

WANT_LOGS=0
[ "${1:-}" = "--logs" ] && WANT_LOGS=1

# Override to test a build in place:  REDROBO_APP=./ReDrobo.app ./check-dext.sh
APP="${REDROBO_APP:-/Applications/ReDrobo.app}"
DEXT_ID="org.redrobo.ReDrobo.DroboDext"
# Read from whatever is installed rather than hardcoding an identity.
TEAM="$(codesign -dv "${REDROBO_APP:-/Applications/ReDrobo.app}" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p')"

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mno\033[0m    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "Machine"

printf '  '; sw_vers -productName | tr -d '\n'; printf ' '; sw_vers -productVersion
printf '  %s\n' "$(sysctl -n hw.model)"

if csrutil status | grep -q disabled; then ok "SIP disabled"; else
    bad "SIP is still enabled, a development dext will not load"; fi

BOOTARGS="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"
if printf '%s' "$BOOTARGS" | grep -q amfi_get_out_of_my_way; then
    ok "AMFI enforcement off (boot-args: $BOOTARGS)"
else
    bad "amfi_get_out_of_my_way not in boot-args"
    note "boot-args is currently: ${BOOTARGS:-<empty>}"
    note "if you set it and it did not stick, the security policy is Reduced."
    note "Go to recovery, Startup Security Utility, choose Permissive Security."
fi

if systemextensionsctl developer 2>&1 | grep -qi 'enabled\|on$'; then
    ok "driver extension developer mode on"
else
    note "developer mode says: $(systemextensionsctl developer 2>&1 | head -1)"
    note "if that is not 'on', run: systemextensionsctl developer on"
fi

hdr "The app"

if [ -d "$APP" ]; then
    ok "$APP present"
    CSOUT="$(codesign --verify --deep --strict --verbose=4 "$APP" 2>&1)"
    if [ $? -eq 0 ]; then
        ok "signature valid"
    else
        bad "signature does not verify, codesign says:"
        printf '%s\n' "$CSOUT" | sed 's/^/        /'
        note ""
        note ""
        note "Read the codesign output above, it names the actual problem."
        note "This may not even block you: with AMFI enforcement off the app"
        note "can still launch. Try it first, and only chase this if the"
        note "activation in step 5 fails."
        note ""
        note "If you do want to redo the copy, use ditto rather than cp -R,"
        note "it reproduces the bundle byte for byte:"
        note "  sudo rm -rf /Applications/ReDrobo.app"
        note "  sudo ditto ReDrobo.app /Applications/ReDrobo.app"
    fi
    printf '        team/id : %s\n' \
        "$(codesign -dv "$APP" 2>&1 | grep -E 'TeamIdentifier|Identifier=' | tr '\n' ' ')"
    if [ -f "$APP/Contents/embedded.provisionprofile" ]; then
        note "has an embedded provisioning profile"
    else
        note "no provisioning profile, so it relies on AMFI being off"
    fi
else
    bad "$APP is missing, copy it over and try again"
fi

hdr "The embedded driver bundle"

SX="$APP/Contents/Library/SystemExtensions"
NDEXT="$(ls -d "$SX"/*.dext 2>/dev/null | wc -l | tr -d ' ')"
DEXTDIR="$(ls -d "$SX"/*.dext 2>/dev/null | head -1)"
if [ "$NDEXT" -gt 1 ]; then
    bad "$NDEXT .dext bundles inside the app, there must be exactly one"
    ls -d "$SX"/*.dext 2>/dev/null | sed 's|.*/|          |'
    note "ditto MERGES into an existing directory, it does not replace it, so"
    note "old builds pile up when the bundle name changes. sysextd then fails"
    note "with OSSystemExtensionErrorExtensionNotFound (error 4)."
    note "Delete both copies and extract fresh:"
    note "  sudo rm -rf /Applications/ReDrobo.app ./ReDrobo.app"
    note "  ditto -x -k ReDrobo-app.zip ."
fi
if [ -z "$DEXTDIR" ]; then
    bad "no .dext inside $SX"
else
    ok "found $(basename "$DEXTDIR")"
    if [ -d "$DEXTDIR/Contents" ]; then
        bad "it uses a Contents/ layout. A .dext must be FLAT, with Info.plist"
        note "at the top level. sysextd silently skips the wrong shape and then"
        note "reports 'Extension not found in App bundle'."
    elif [ -f "$DEXTDIR/Info.plist" ]; then
        ok "flat layout, Info.plist at the top level"
    else
        bad "no Info.plist anywhere obvious in the bundle"
    fi
    DBASE="$(basename "$DEXTDIR" .dext)"
    DEXE="$(plutil -extract CFBundleExecutable raw "$DEXTDIR/Info.plist" 2>/dev/null)"
    DID="$(plutil -extract CFBundleIdentifier raw "$DEXTDIR/Info.plist" 2>/dev/null)"
    if [ "$DBASE" = "$DID" ] && [ "$DID" = "$DEXE" ]; then
        ok "bundle dir, identifier and executable all agree"
    else
        bad "bundle dir, identifier and executable must be the same string"
        note "sysextd looks for <identifier>.dext by name. Yours:"
        note "  dir        $DBASE"
        note "  identifier $DID"
        note "  executable $DEXE"
    fi
    [ -f "$DEXTDIR/$DEXE" ] || bad "executable $DEXE missing from the bundle"
    AID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null)"
    printf '        app  id : %s\n' "$AID"
    printf '        dext id : %s\n' "$DID"
    case "$DID" in
        "$AID".*) ok "dext id is prefixed by the app id, as required" ;;
        *)        bad "dext id must be prefixed by the app id" ;;
    esac
    printf '        pkg type: %s, platform: %s, minDriverKit: %s\n' \
        "$(plutil -extract CFBundlePackageType raw "$DEXTDIR/Info.plist" 2>/dev/null)" \
        "$(plutil -extract CFBundleSupportedPlatforms.0 raw "$DEXTDIR/Info.plist" 2>/dev/null)" \
        "$(plutil -extract OSMinimumDriverKitVersion raw "$DEXTDIR/Info.plist" 2>/dev/null)"
    # lipo needs the developer tools, which a plain test Mac will not have.
    # file(1) is always present and names the slices well enough.
    if command -v lipo >/dev/null 2>&1; then
        ARCHS="$(lipo -archs "$DEXTDIR/$DEXE" 2>/dev/null)"
    else
        ARCHS="$(file "$DEXTDIR/$DEXE" 2>/dev/null \
                 | grep -oE 'arm64e|arm64|x86_64' | sort -u | tr '\n' ' ')"
    fi
    printf '        archs   : %s\n' "${ARCHS:-<could not determine>}"
    if [ -z "$ARCHS" ]; then
        note "could not read the architectures, skipping that check"
    elif [ "$(uname -m)" = "arm64" ] && ! printf '%s' "$ARCHS" | grep -q arm64e; then
        bad "on Apple Silicon a dext must be arm64e, not plain arm64"
        note "the kernel refuses to exec a plain arm64 dext and kernelmanagerd"
        note "logs: Error launching dext ... Code=8 \"Exec format error\""
    else
        ok "architecture slice is right for this Mac"
    fi
    if codesign --verify --strict "$DEXTDIR" 2>/dev/null; then
        ok "dext signature valid"
    else
        bad "dext signature invalid: $(codesign --verify --strict "$DEXTDIR" 2>&1 | head -1)"
    fi
fi

hdr "The driver"

EXTS="$(systemextensionsctl list 2>&1)"
if printf '%s' "$EXTS" | grep -q "$DEXT_ID"; then
    printf '%s\n' "$EXTS" | grep -A1 "$DEXT_ID" | sed 's/^/  /'
    NENT="$(printf '%s' "$EXTS" | grep -c "$DEXT_ID")"
    if [ "$NENT" -gt 1 ]; then
        bad "$NENT entries for this identifier, the database is jammed"
        note "sysextd logs a Fault: 'activateDecision found two entries'."
        note "It happens when the same version is reinstalled. Clear it with:"
        note "  systemextensionsctl uninstall $TEAM $DEXT_ID"
        note "or, if that will not shift it, reboot. As a last resort on a"
        note "throwaway Mac:  systemextensionsctl reset   (removes ALL of them)"
    elif printf '%s' "$EXTS" | grep "$DEXT_ID" | grep -q 'activated enabled'; then
        ok "activated and enabled"
    else
        bad "present but not active, see the state above"
    fi
else
    bad "$DEXT_ID not registered yet, press Install driver in the app"
fi

echo
echo "  IORegistry:"
if ioreg -c IOUserService -w0 2>/dev/null | grep -qi DroboDext; then
    ioreg -c IOUserService -w0 2>/dev/null | grep -i DroboDext | sed 's/^/    /'
else
    note "no DroboDext service. Either not activated, or activated but it did"
    note "not match the device."
fi

hdr "Which build is actually running"

RUNNING="$(log show --last 30m --predicate 'eventMessage CONTAINS "DroboDext: started"' \
           --info 2>/dev/null | tail -1)"
if [ -n "$RUNNING" ]; then
    printf '        %s\n' "$(printf '%s' "$RUNNING" | sed 's/.*DroboDext: //')"
    note "Compare that with the version listed above. Replacing a dext does not"
    note "terminate the running one, so the kernel keeps the old binary until"
    note "you reboot. If they differ, reboot before testing anything."
else
    note "no start message in the last 30 minutes"
    note "builds before 6 did not log their version, so this may just be an old one"
fi

hdr "The Drobo"

if ioreg -c IOSCSIPeripheralDeviceNub -r -w0 2>/dev/null | grep -qi drobo; then
    ok "enclosure is attached to this Mac"
    ioreg -c IOSCSIPeripheralDeviceNub -r -w0 2>/dev/null \
        | grep -E '"Vendor Identification"|"Product Identification"|"Product Revision Level"' \
        | sed 's/^ */    /' | head -3
    diskutil list external 2>/dev/null | grep -E '^/dev/|Apple_HFS' | sed 's/^/    /'
    SLICE="$(diskutil list external 2>/dev/null | awk '/Apple_HFS/{print $NF}' | head -1)"
    if [ -n "$SLICE" ]; then
        MP="$(diskutil info "$SLICE" 2>/dev/null | awk -F': +' '/Mount Point/{print $2}')"
        if [ -n "$MP" ]; then
            ok "volume mounted at $MP"
        else
            bad "volume $SLICE present but NOT mounted"
        fi
    else
        bad "no HFS volume from the Drobo at all"
    fi
else
    bad "no Drobo on this Mac. Plug it in over USB, the test needs it here."
fi

if [ $WANT_LOGS -eq 1 ]; then
    hdr "Recent logs"
    echo "  --- sysextd ---"
    log show --last 15m --predicate 'process == "sysextd" OR subsystem == "com.apple.sx"' --info 2>/dev/null \
        | tail -30 | sed 's/^/    /'
    echo "  --- the driver itself ---"
    log show --last 15m --predicate 'eventMessage CONTAINS "DroboDext"' --info 2>/dev/null \
        | grep -vE 'fsevents|UserEventAgent|RunningBoard|launchservices|ContextStore' \
        | tail -30 | sed 's/^/    /'
    echo "  --- AMFI and codesigning ---"
    log show --last 15m --predicate 'sender == "AMFI" OR eventMessage CONTAINS[c] "redrobo"' --info 2>/dev/null \
        | tail -20 | sed 's/^/    /'
fi

echo
