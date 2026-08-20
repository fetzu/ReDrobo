# The DriverKit driver: it works

Date: 2026-08-19. Mac mini (M1) running macOS 27.0 beta (26A5388g),
SIP disabled, `systemextensionsctl developer on`, `amfi_get_out_of_my_way=1`.
Drobo 5D attached over USB 3, volume mounted throughout.

Nothing was written to the enclosure at any point.

## Result

A DriverKit driver extension reads Drobo ESA management records on macOS 27,
Apple Silicon, **with the volume mounted**. From the system log, build 9:

```
DroboDext: started, build 9
DroboDext: diag: UserReportMediumBlockSize -> 0x0 (512)
DroboDext: diag TEST UNIT READY: UserSendCDB -> 0x0, scsiStatus 0x0, serviceResponse 0x2, got 0
DroboDext: diag INQUIRY:        UserSendCDB -> 0x0, scsiStatus 0x0, serviceResponse 0x2, got 36
DroboDext: diag MODE SENSE all: UserSendCDB -> 0x0, scsiStatus 0x0, serviceResponse 0x2, got 8
DroboDext: diag ESA page 0x01:  UserSendCDB -> 0x0, scsiStatus 0x0, serviceResponse 0x2, got 1308
```

`kIOReturnSuccess`, SCSI status GOOD, service response TASK_COMPLETE, and the
full 1308 byte ESA record. That is the whole design proven end to end.

## Three bugs, and the order they had to be fixed in

Getting here took an embarrassing number of attempts because the first bug
masked the second, and the second made the third untestable.

### 1. `IOClass` was the generic kernel class

```
IOClass = IOUserService            wrong
IOClass = IOUserSCSIPeripheralDeviceType00   correct
```

`IOClass` names the class the **kernel** instantiates; `IOUserClass` names the
class in the dext. PCIDriverKit tolerates the generic `IOUserService`;
SCSIPeripheralsDriverKit does not. With the wrong one the kernel has no callout
hooks for `UserSendCDB`, `UserReportMediumBlockSize` and the rest, and every
call returns `kIOReturnUnsupported` (`0xe00002c7`) from an unimplemented stub.

This is the single most misleading failure in the whole exercise. It looks
exactly like a permissions problem and is not one. An Apple DTS engineer
describes it as "an undocumented implementation detail".

### 2. `IOMatchCategory` was set

Apple's guidance is blunt: most dexts must not include this key, and it is only
for `IOProviderClass = IOUserResources`. Setting it makes the in-kernel driver
load *beside* the dext, open the provider and block the dext's access. That is
precisely what happened: Apple's `IOSCSIPeripheralDeviceType00` kept the volume
mounted while ours sat alongside with no authority over the device.

Removed. The dext now competes in the default match category and wins on probe
score, because matching on Vendor and Product Identification is more specific
than Apple's generic `Peripheral Device Type = 0`. Exactly how Drobo's own kext
won the same contest.

There is now also a Vendor-only pair of personalities, so that models nobody
here can plug in are still picked up without guessing their INQUIRY product
strings. `IOSCSIPeripheralDeviceNub::matchPropertyTable` only checks the keys a
personality actually carries, so omitting `Product Identification` matches every
Drobo. Whether a Vendor-only match still outscores Apple's driver is **not
tested**: that contest has only ever been run on a 5D, where the specific
personality wins anyway. If another model turns up as connected-but-unclaimed,
that is the reason, and the app prints the strings needed to add a specific
personality for it.

### 3. The family entitlement is required, and it is the CONTROLLER one

Only after fixing 1 and 2 does the kernel reach the check, and then it says so:

```
DK: DroboDext-0x1000009e5: family entitlements check failed
DK: IOUserServer(...)::exit(Entitlements check failed)
```

The answer, confirmed on hardware:

```xml
<key>com.apple.developer.driverkit.family.scsicontroller</key>
<true/>
```

**`SCSIPeripheralsDriverKit` shares the SCSI *controller* family entitlement.**
Apple never minted a peripheral-side key, which is exactly why none appears in
their documentation, in the entitlement index, or in any readable kernel image.
Hours were spent looking for a string that does not exist.

Found by brute force. Thirteen plausible spellings were signed into one build,
which passed, then narrowed:

| Build | Entitlement signed alone | Result |
|---|---|---|
| 10 | `family.scsi-peripherals` | check failed |
| 11 | `family.scsiperipherals` | check failed |
| 12 | `family.scsicontroller` | **started** |

**With `amfi_get_out_of_my_way=1` the kernel honours whatever entitlements are
in the signature**, which is what makes the name discoverable locally at all.
Without that, this would have required asking Apple to guess along with you.

The practical consequence is larger than it first looked: `family.scsicontroller`
is **documented and requestable** (macOS 11.3), and on a machine of your own it
does not even have to be requested. That part is below, under "Two ways off the
boot-args".

### Why the earlier "it is not an entitlement" conclusion was also wrong

Partway through, an Apple forum thread said plainly "no, this is not an
entitlement issue", and that was correct *for the question being asked there*,
which was about `UserSendCDB` refusing vendor-specific opcodes. It was not
correct for our failure, which was bug 1. Both statements are true about
different things, and conflating them cost time in both directions: first
assuming entitlements when it was `IOClass`, then assuming `IOClass` when the
entitlement gate was also real.

## What this means for the enclosure

Standard SCSI opcodes are non-disruptive and need no exclusive access, which the
live run confirms: `MODE SENSE(10)` on vendor page `0x3A` returned a full record
while the filesystem stayed mounted. A live status monitor is therefore
possible, not just an unmount-first diagnostic tool.

Vendor-specific opcodes in `0xC0`-`0xFF` are a different matter. Those require
`UserSuspendServices()`, which requires unmounting, and per Apple there is no
way around that. Drobo's protocol does not need them, so it does not matter here.

## Packaging rules that each cost a debugging round

All of these are things Xcode does for you and a hand-rolled build does not.

1. The extension's bundle identifier must be prefixed by the containing app's.
2. A `.dext` is a **flat** bundle. `Info.plist` sits at the top level, not under
   `Contents/`.
3. The bundle directory name, `CFBundleIdentifier` and `CFBundleExecutable` must
   all be the same string. `sysextd` locates the extension by filename.
4. `CFBundleSupportedPlatforms` must be `[DriverKit]`, and
   `OSMinimumDriverKitVersion` must be present.
5. On Apple Silicon the binary must be **arm64e**. A plain arm64 dext gives
   `Error launching dext ... Code=8 "Exec format error"`.
6. `UserClientProperties` belongs **inside each IOKitPersonalities entry**, not
   at the top level. `Create()` looks it up on the service's own property table.

## Lifecycle traps

**Replacing a dext does not terminate the running one.**
`systemextensionsctl list` shows the new version as current while the kernel
keeps executing the old binary until a reboot. Always reboot before drawing
conclusions, and log the build number from `Start()` so you can tell which is
live. Several "failures" here were simply the previous build still running.

**Reinstalling the same version jams the database**, leaving one entry stuck in
`terminating_for_upgrade_via_delegate` and a `Fault` from `activateDecision`.
Bump `CFBundleVersion` every single time. `make bump` does it.

**The build number must come from one place.** It used to be a `#define` in
`DroboDext.cpp` as well as `CFBundleVersion` in `Info.plist`, and the first
`make bump` moved one and not the other. The log line that exists specifically
to tell you which build is live then said 12 no matter what was running, which
is worse than having no check at all. It now comes from the plist via a `-D` in
the Makefile, and the same value is stamped into every personality as
`DroboBuild`. IOKit copies a matching personality's properties onto the service
it creates, so the app can read `DroboBuild` off the matched service and compare
the *running* build against what `sysextd` says is *installed*.

**`ditto -x -k` merges into an existing directory** rather than replacing it, so
old bundles accumulate when a name changes and `sysextd` then reports
`OSSystemExtensionErrorExtensionNotFound`. Delete both the local and the
installed copy before extracting.

**`com.apple.FinderInfo`** lands on the app bundle when a zip is opened by
double-click, and `codesign` refuses any bundle carrying it. Extract with
`ditto -x -k`, or clear it with `xattr -cr`.

**`os_log` redacts `%s` as `<private>`.** Four of five probe results were
invisible until the format string was changed to `%{public}s`. Worth knowing
before concluding that code did not run.

## Reproducing

See `docs/TESTING.md` for the machine setup. In short: SIP off,
`systemextensionsctl developer on`, `amfi_get_out_of_my_way=1`, app in
`/Applications`, reboot after every driver replacement.

That is the no-developer-account version, and it is the one everything above was
measured on. If you do have an account, do the provisioning profiles first and
the boot-arg drops straight out of that list.

## Undoing the test machine

```bash
sudo nvram -d boot-args
```

Then `csrutil enable` from recoveryOS.

## Two ways off the boot-args (they are not the same way)

`amfi_get_out_of_my_way=1` is the worst thing in this document. It does not
relax the rules for this driver, it relaxes them for every process on the
machine: anybody's code, carrying any entitlement anybody cares to sign into it.
Getting rid of it, and getting this driver onto a Mac belonging to someone else,
turn out to be two separate problems with two different answers.

### 1. Your own Macs, which needs nobody's permission

Since Xcode 14 (2022) Apple splits the DriverKit capabilities by profile type.
Quinn, of Apple's Developer Technical Support, on the developer forums: for
development profiles "these capabilities are no longer managed", so any
developer can add them to any App ID on the portal and they flow through into
the development provisioning profiles made from it. They stay managed for
distribution profiles.

Which means the two keys that cost an afternoon of brute force up there are a
form to fill in rather than a negotiation. `docs/PROVISIONING.md` is the
step-by-step; in outline, roughly 45 minutes and a paid membership:

- two App IDs: `org.redrobo.ReDrobo` with System Extension and Communicates
  with Drivers, `org.redrobo.ReDrobo.DroboDext` with the DriverKit ones
- every Mac it has to run on, registered by its Provisioning UDID
  (`system_profiler SPHardwareDataType`)
- a DriverKit App Development profile for the driver, an ordinary macOS
  development profile for the app
- both dropped next to the Makefile as `DroboDext.provisionprofile` and
  `ReDrobo.provisionprofile`, which `make` picks up on its own

No code changes anywhere. A provisioning profile is precisely the mechanism that
boot-arg exists to defeat, so the boot-arg goes and AMFI goes back to enforcing
everything else on the machine.

And SIP goes back on too, which was the open question here until 2026-08-20.

Measured that day on a MacBook Pro (Mac17,9) running macOS 26.6.2 (25G83), SIP
**enabled**, no boot-args set at all, developer mode not even available (the
tool refuses to run while SIP is on). App copied to `/Applications`, opened,
Install driver pressed, approved in System Settings:

```
enabled	active	teamID	bundleID (version)	name	[state]
*	*	H2N329D9U8	org.redrobo.ReDrobo.DroboDext (1.0.0/16)	ReDrobo Driver	[activated enabled]
```

Two separate things fall out of that. The app carries
`com.apple.developer.system-extension.install`, a restricted entitlement, and it
launched rather than being SIGKILLed: AMFI honours a restricted entitlement
under full SIP purely because a provisioning profile authorises it. And
`sysextd` then activated a development-signed extension that has never been near
the notary.

The second one contradicts the folklore, including the Karabiner-DriverKit
project's own notes, which say flatly that a dext has to be notarized once SIP
is enabled. That is true of a Developer ID build. It is **not** true of a build
signed for development with a profile that names the machine it is running on:
the profile is what the system trusts, and the device list is what makes
trusting it safe. Apple's documentation never says this either way, which is
presumably how the folklore got started.

And the last link closed the same day. A Drobo 5D was plugged into that same
MacBook Pro, still SIP enabled, still no boot-args, still no developer mode, and
the driver matched it, started, and read it: capacity, bays, health, the lot.
The family entitlement check passes at match time on a Mac with every defence
up.

So the whole chain is proven end to end on a machine in the state Apple ships
it. Everything above about SIP, AMFI and boot-args describes how this was found
out, not what it takes to run it.

Two limits worth knowing before starting: a development profile is good for one
year, and it covers the machines listed in it and no others.

### 2. Everybody else's Macs, which means asking Apple

For a build that loads on a Mac neither of us has ever seen, with SIP on, the
driver has to be signed with a Developer ID certificate and notarized, and at
that point the capabilities are managed again. That means requesting
`com.apple.developer.driverkit` and
`com.apple.developer.driverkit.family.scsicontroller` on the driver's App ID,
and `com.apple.developer.driverkit.userclient-access` on the app's.

Since June 2025 that request happens inside the portal and not through a web
form: Certificates, Identifiers & Profiles, then Identifiers, then the App ID,
then the **Capability Requests** tab, then Request. Status and any notes from
Apple come back on that same tab, which is a real improvement on the old form
(which answered by e-mail, or did not answer). Account Holder role required, and
the App ID has to exist before you can request anything against it.

Do not go looking for the form Apple's own documentation points at.
`developer.apple.com/contact/request/system-extension/` is linked from the
DriverKit documentation and from Apple's System Extensions page, and it has been
404 since the portal change. Expect weeks either way.

The case is stronger than it feels from the outside. Apple's DTS has said on the
record that they do approve requests from third parties rather than only from
the vendor whose name is on the box, and that they lean towards approving rather
than rejecting. Nothing here is scoped to a USB vendor and product ID, so it
sidesteps the wildcard entitlement argument Apple refuses outright. The driver
only reads, with standard opcodes, and never touches the vendor-specific range.
And the request can point at something that already loads, matches and reads
real hardware, which makes for a considerably better letter than a proposal.

Once granted, the resulting build outlives the membership: a Developer ID
provisioning profile issued after 22.02.2017 is valid for 18 years, and a
notarized app keeps launching for as long as its certificate was valid on the
day it was signed. The account is what you need in order to *make* a build, not
what the build needs in order to keep working.
