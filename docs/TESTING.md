# Testing DroboDext

The driver is built and signed. What is left is the part only you can do:
getting a Mac to accept a driver extension that did not come from Apple.

Read this whole page before starting. There are two ways to do it, they are not
equally pleasant, and only one of them touches your Mac's security settings.

## Two routes, and you only need one

**Route A, a provisioning profile.** Costs a paid Apple developer account and
about an hour on Apple's portal. Costs nothing else: System Integrity Protection
stays on, no boot-args, the Mac stays exactly as Apple shipped it. The DriverKit
capabilities this driver needs are self-serve for development, so there is
nothing to request from Apple and nobody to wait for.

Confirmed on 2026-08-20, on a MacBook Pro running macOS 26.6.2 with SIP enabled
and no boot-args at all: the driver installs, activates, matches a Drobo 5D and
reads it. Details in `docs/DRIVERKIT.md`.

**Route B, turn the checks off.** Costs nothing and needs no account. Costs you
the machine's defences instead: SIP off, and AMFI told to ignore entitlements,
apply to everything running on that Mac rather than to ReDrobo alone. Use a
spare machine.

Route A is better in every respect except the one that matters if you do not
have an account. Both are below. Do one.

## Before you start

- Plug the Drobo into the **test** Mac over USB. The iMac is not involved.
- On route B, know that you will reboot twice, into recovery once. On route A,
  not at all.
- Nothing here writes to the enclosure. The driver only issues MODE SENSE(10).

### If the test Mac is headless, read this first

**Route B cannot be done over Remote Desktop.** Apple Silicon requires One True
Recovery, holding the power button at boot, and Apple built that specifically so
only a physically present user can lower the security settings. recoveryOS has
no screen sharing.

The system extension approval in System Settings is a user-presence protected
control too, of the same kind that historically refuses synthetic clicks over
screen sharing. Developer mode skips version checks but does not reliably remove
that approval step.

So: attach a display and a keyboard for the SIP step and through activation,
then unplug them and go back to remote access. Note also that macOS 15 and later
prompt after every reboot before letting third party remote access apps back in,
which on a headless machine is its own trap. Apple's built in Screen Sharing
with Remote Management enabled does not have that problem.

### Building on one Mac, testing on another

Perfectly fine, and usually easier: your signing identity and Xcode stay on the
machine you already use.

On the build Mac:

```bash
make dist
```

Copy `ReDrobo-app.zip` across, then on the test Mac:

```bash
ditto -x -k ReDrobo-app.zip . && xattr -dr com.apple.quarantine ReDrobo.app && sudo cp -R ReDrobo.app /Applications/
```

Use `ditto`, not Finder's zip: it keeps the signature and the bundle structure
intact. Skip steps 2 and 3 below in that case, they are for building in place.

## 1. Get the entitlements honoured

The app and the driver carry **restricted** entitlements:
`system-extension.install` on the app, the `driverkit` keys on the driver. They
are only honoured if the system has a reason to trust them, and without one AMFI
kills the app the instant it execs. The crash report says
`Namespace CODESIGNING, Code 1, Taskgated Invalid Signature` with an empty
`codeSigningID`, which reads like a broken signature and is not one: the
signature is fine, the entitlements are the problem. Verified by experiment, the
same binary re-signed with no entitlements at all launches normally.

`make doctor` tells you where you stand at any point, for either route.

### Route A: embed provisioning profiles

**[PROVISIONING.md](PROVISIONING.md) is this route written out in full**, and
you want it rather than the summary here, because every step of it has a trap
that announces itself as something else. In outline:

1. Two App IDs, one for the app with **System Extension**, one for the driver
   with **DriverKit (development)**, **DriverKit Family SCSIController
   (development)** and **DriverKit Allow Any UserClient (development)**. All
   checkboxes, all granted to anybody who ticks them.
2. Every Mac it has to run on, registered under Devices by its Provisioning
   UDID.
3. Two profiles, **DriverKit App Development** for the driver and ordinary macOS
   development for the app, dropped next to the Makefile as
   `DroboDext.provisionprofile` and `ReDrobo.provisionprofile`.

Then skip to step 2 and leave SIP alone. A profile naming the machine is all
macOS asks for, and contrary to a good deal of folklore a development build does
**not** have to be notarized to install with SIP on.

A development profile covers the machines listed in it and no others, and
expires after a year.

### Route B: turn the checks off

No account needed. Only on a Mac you are willing to weaken.

Turn SIP off. Shut down, hold the power button until "Loading startup options"
appears, then Options, Utilities, Terminal:

```bash
csrutil disable
```

Reboot into macOS normally, then turn on driver extension developer mode:

```bash
systemextensionsctl developer on
```

That command fails while SIP is on, which is a useful check that the previous
step took. Then stop AMFI enforcing entitlements:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1"
```

Reboot again, and confirm it stuck:

```bash
nvram boot-args
```

If it did not stick, the security policy is Reduced rather than Permissive. Go
back to recovery, open Startup Security Utility, choose Permissive Security, and
try again. Step 6 puts all of it back.

## 2. Build

```bash
cd ReDrobo && make
```

Signs with your Apple Development identity. Override with
`make SIGN_ID="..."` if you would rather use a different identity.

## 3. Install into /Applications

```bash
cd ReDrobo && make install
```

The system refuses to activate an extension from an app anywhere else, so this
step is not optional.

## 4. Activate

Open `/Applications/ReDrobo.app` and press **Install driver**.

macOS may ask for approval in System Settings, under General, then Login Items
and Extensions, then Driver Extensions. Approve it there and press the button
again.

Check what happened:

```bash
systemextensionsctl list
```

You want to see `org.redrobo.ReDrobo.DroboDext` marked `activated enabled`.

## 4b. Reboot after replacing a driver

Not optional, and it cost us a round.

When you activate a new build over a running one, `sysextd` asks the old dext to
terminate. `kernelmanagerd` declines, because the extension is mid-replacement:

```
Dext ... v3 ... is being replaced and cannot be terminated right away
turning the responsibility for termination ... over to delegate
  (with uninstallation at the next reboot)
```

The new version reaches `activated_enabled` and `systemextensionsctl list` shows
it as current, but **the kernel keeps running the old binary until you reboot**.
The symptom is confusing: your new code is installed, yet the driver behaves like
the previous build. Ours announced it by refusing a selector that only the old
build lacked.

So after every Install driver, reboot before drawing conclusions. The driver
logs its own build number on start, so you can check which one is really live:

```bash
log show --last 5m --predicate 'eventMessage CONTAINS "DroboDext: started"' --info
```

That number now comes from `CFBundleVersion` by way of a `-D` in the driver's
Makefile, so it cannot drift from the bundle the way a literal in the source
did. The same value is stamped into every personality as `DroboBuild`, which is
how the app reads back the build that is *running* rather than the one that is
installed. When the two differ, the app says so at the top of the window and in
Settings ▸ Driver, and the answer is always: restart.

## 5. Read the enclosure

There is nothing to press. The app polls on its own and fills in the four panes:
capacity, the six slots with their models, the enclosure name, firmware, the
85 % threshold. The same values `tools/droboesa` pulled off the iMac.

If it does not, the app should now say which of the three things went wrong
rather than guessing: the driver is not installed, no enclosure is connected, or
an enclosure is connected but the driver did not claim it. That last one prints
the exact `Vendor Identification` and `Product Identification` strings, which is
what a new model needs adding to `DroboDext/Info.plist`.

Two things to watch for, because they are the real questions:

- **Does the volume stay mounted?** It should. MODE SENSE(10) is a standard
  opcode, so no exclusive access is needed. If the volume drops, that assumption
  was wrong and it matters.
- **Do the numbers match `drobo-space`?** If yes, the driver is correct.

## 6. Putting the Mac back

Route A leaves nothing to undo. SIP was never off.

For route B, do it the same day. The boot-arg first:

```bash
sudo nvram -d boot-args
```

Then SIP, from recovery, and put the security policy back to Full while you are
in there:

```bash
csrutil enable
```

A build with no provisioning profile stops loading at that point, which is
expected: that is the entire difference between the two routes. Everything stays
in the repo and reinstalls in minutes if you later get an account and take route
A.

## When it does not work

Ask the system why, rather than guessing:

```bash
log show --last 10m --predicate 'subsystem == "com.apple.sysextd"' --info
```

```bash
log show --last 10m --predicate 'sender == "DroboDext"' --info
```

Common outcomes and what they mean:

| Symptom | Meaning |
|---|---|
| `Extension not found in App bundle` | The dext bundle is malformed in a way sysextd silently skips. Two causes bit us: its bundle ID must be **prefixed by the app's**, and a `.dext` is a **flat** bundle with `Info.plist` at the top level, not a macOS `Contents/` bundle. Compare against anything in `/System/Library/DriverExtensions`. |
| App is SIGKILLed at launch, `Taskgated Invalid Signature` | Restricted entitlements with no provisioning profile. See step 2b. `make doctor` confirms it. |
| `Disallowed xattr com.apple.FinderInfo` | Finder metadata on the bundle, usually from unzipping by double-click. `sudo xattr -cr /Applications/ReDrobo.app`, no re-signing needed. Extract with `ditto -x -k` to avoid it. |
| Activation refused, log names an entitlement | The answer we came for. Add the key to `DroboDext.entitlements` and note it in the repo. |
| Activated, but `Read Drobo` says no service | The dext loaded but did not match. Compare `Vendor Identification` and `Product Identification` in `Info.plist` against `ioreg -c IOSCSIPeripheralDeviceNub -r`. |
| Matched, but records fail | Check the `UserSendCDB` return in the log. Most likely the CDB or the buffer mapping, not the protocol, since the protocol is already confirmed. |
| Volume unmounts when reading | The no-exclusive-access assumption is wrong. Would need `UserSuspendServices`, which changes the design. |

Whatever happens, save the log output. A refusal that names the entitlement is
a good result, not a failure.
