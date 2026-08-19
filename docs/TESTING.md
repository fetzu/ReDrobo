# Testing DroboDext

The driver is built and signed. What is left is the part only you can do:
putting the Mac into a state where it will load a development driver.

Read this whole page before starting. Step 1 weakens your Mac's security and
step 7 puts it back.

## What this proves, and what it does not

With SIP off, macOS relaxes entitlement checking for driver extensions. That is
enough to answer the question we actually care about: **does
`IOUserSCSIPeripheralDeviceType00` work for a Drobo, and can it read the ESA
records with the volume mounted?**

It does not give you a driver you can live with. For that the dext has to load
with SIP on, which needs the SCSI-peripheral family entitlement from Apple. The
useful side effect of this test is that if the load is refused, the log names
the exact entitlement key, which is the thing I could not find in Apple's public
documentation.

## Before you start

- Plug the Drobo into the **test** Mac over USB. The iMac is not involved.
- Know that you will reboot twice, into recovery once.
- Nothing here writes to the enclosure. The driver only issues MODE SENSE(10).

### If the test Mac is headless, read this first

**You cannot do this over Remote Desktop.** Apple Silicon requires One True
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
intact. Skip steps 3 and 4 below in that case, they are for building in place.

## 1. Turn SIP off

Shut down, then hold the power button until "Loading startup options" appears.
Choose Options, then Utilities, then Terminal, and run:

```bash
csrutil disable
```

Reboot into macOS normally.

## 2. Turn on driver extension developer mode

```bash
systemextensionsctl developer on
```

This fails while SIP is on, which is the check that step 1 passed.

## 2b. Deal with the provisioning profile problem

This one bit us on the first attempt, so do it before building.

The app carries **restricted** entitlements: `system-extension.install` and the
`driverkit` keys. On a development-signed build those are only honoured if a
matching provisioning profile is embedded in the bundle. Without one, AMFI kills
the process the instant it execs, and the crash report says
`Namespace CODESIGNING, Code 1, Taskgated Invalid Signature` with an empty
`codeSigningID`. The signature itself is fine; the entitlements are the problem.

Verified by experiment: the same binary re-signed with no entitlements at all
launches normally.

Run `make doctor` and it will tell you which of these you need.

### Option A, the correct one: embed provisioning profiles

On developer.apple.com, create two App IDs, `org.redrobo.ReDrobo` with the
System Extension capability and `org.redrobo.ReDrobo.DroboDext` with the DriverKit ones,
make a development provisioning profile for each, and drop them next to the
Makefile as `ReDrobo.provisionprofile` and `DroboDext.provisionprofile`. The
build embeds them automatically.

Worth doing even if you use Option B to run the test, because the capability
list on that page answers the strategic question directly: **if the DriverKit
family capabilities are not offered to your account, the whole dext route is
closed and no amount of local testing changes that.** Five minutes to find out.

### Option B, the fast one: stop AMFI enforcing

Only on a throwaway test Mac that already has SIP off.

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1"
```

Reboot, then confirm it stuck:

```bash
nvram boot-args
```

If it did not stick, the security policy is Reduced rather than Permissive. Go
back to recovery, open Startup Security Utility, choose Permissive Security, and
try again.

Undo it later with `sudo nvram -d boot-args`.

## 3. Build

```bash
cd ReDrobo && make
```

Signs with your Apple Development identity. Override with
`make SIGN_ID="..."` if you would rather use a different identity.

## 4. Install into /Applications

```bash
cd ReDrobo && make install
```

The system refuses to activate an extension from an app anywhere else, so this
step is not optional.

## 5. Activate

Open `/Applications/ReDrobo.app` and press **Install driver**.

macOS may ask for approval in System Settings, under General, then Login Items
and Extensions, then Driver Extensions. Approve it there and press the button
again.

Check what happened:

```bash
systemextensionsctl list
```

You want to see `org.redrobo.ReDrobo.DroboDext` marked `activated enabled`.

## 5b. Reboot after replacing a driver

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

## 6. Read the enclosure

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

## 7. Turn SIP back on

Do this the same day. Recovery again:

```bash
csrutil enable
```

The dext stops loading once SIP is back on, which is expected. Everything stays
in the repo and reinstalls in minutes once the entitlement question is settled.

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
