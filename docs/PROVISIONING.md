# Signing ReDrobo yourself

How to get macOS to load the driver without touching a single security setting:
SIP on, no boot-args, the Mac exactly as Apple shipped it. This is route A from
[TESTING.md](TESTING.md), written out in full, because the developer portal is
where all the traps are and not one of them announces itself.

An hour the first time, and everything here is self-serve. Nothing has to be
requested from Apple, nobody has to approve anything, and no part of it is
gated on the DriverKit entitlement request that the rest of the internet will
tell you is mandatory. It is not, for development. It is for distribution, which
is [a different section](#what-this-does-not-get-you).

## What you need

- **A paid Apple Developer Program membership.** The free tier cannot register
  App IDs or create provisioning profiles, so it cannot do any of this.
- **The Account Holder role.** On an individual membership that is you by
  definition. On an organization one, only the Account Holder can create a
  profile carrying restricted entitlements; an Admin will get an unhelpful
  "unexpected error" on the portal instead.
- **An Apple Development signing identity:**

```bash
security find-identity -v -p codesigning
```

You want a line reading `Apple Development: Your Name (XXXXXXXXXX)`. If there
is none, Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + makes one. The
identifier in the parentheses is the certificate's, not your team's: the team ID
is the `OU` field, which `security find-certificate -c "Apple Development" -p |
openssl x509 -noout -subject` will show you if you need it.

## 0. Change the bundle identifiers, unless this is your repo

Explicit App IDs are unique across every Apple developer account in the world,
so `org.redrobo.ReDrobo` is registered and you cannot have it. Pick your own
reverse DNS prefix and replace it throughout. Two rules constrain what you may
choose:

- the driver's identifier must be **prefixed by the app's**
  (`com.example.ReDrobo` and `com.example.ReDrobo.DroboDext`), because macOS
  refuses to activate an extension whose identifier is not
- the `.dext` bundle directory name, its `CFBundleIdentifier` and its
  `CFBundleExecutable` must all be the **same string**, because `sysextd`
  locates the extension by filename

Seven files carry it:

| File | What is in it |
|---|---|
| `ReDrobo/Info.plist` | the app's `CFBundleIdentifier` |
| `DroboDext/Info.plist` | the driver's identifier and executable name, `IOUserServerName`, and a `CFBundleIdentifier` in each of the 26 personalities |
| `ReDrobo/Makefile` | `DEXT`, the bundle directory name |
| `DroboDext/Makefile` | the same name again |
| `ReDrobo/DroboIOKit.swift` | the identifier the app looks the driver up by |
| `ReDrobo/Log.swift` | the `os_log` subsystem |
| `ReDrobo/ReDrobo.entitlements` | inside a comment, in the snippet to restore later |

A find and replace of `org.redrobo` covers all of it.

## 1. Two App IDs

Certificates, Identifiers & Profiles ▸ Identifiers ▸ + ▸ App IDs ▸ App. Explicit
bundle ID, not wildcard. Do it twice.

**For the app**, tick:

- **System Extension**

**For the driver**, tick:

- **DriverKit (development)**
- **DriverKit Family SCSIController (development)**
- **DriverKit Allow Any UserClient (development)**

Everything tagged "(development)" in that list is yours for the ticking. That
includes the family entitlement, which is the one this whole project spent an
afternoon brute-forcing the name of, and which every discussion of DriverKit
implies you must beg Apple for.

Deliberately **not** ticked:

- **DriverKit USB Transport.** The enclosure arrives over USB, so this looks
  right and is not. The driver matches on `IOSCSIPeripheralDeviceNub`, never
  touches a USB API, and was proven to start with `driverkit` and
  `family.scsicontroller` alone. It is also the entitlement scoped to a specific
  USB vendor and product ID, which drags the whole "what is your vendor ID"
  question in behind it. Leave it.
- **DriverKit Communicates with Drivers.** See the next section, it is the one
  real trap here.
- Everything else. A capability you do not sign against is a capability that
  cannot fail.

## 2. The UserClient trap

The natural design is `com.apple.developer.driverkit.userclient-access` on the
**app**, naming the driver, so that exactly one app may open the user client.
That is the tight, correct arrangement, and you cannot have it either.

In the portal it is called **DriverKit Communicates with Drivers**, and you will
notice it is the one row in that list with no "(development)" suffix and no
"Development only" note. That means it is **managed**: Apple grants it by hand,
on request, and it therefore cannot appear in a profile you made yourself.

This matters because of how AMFI works. Sign a binary with a restricted
entitlement its embedded profile does not grant and the process is SIGKILLed the
instant it execs. The crash report says:

```
Namespace CODESIGNING, Code 1, Taskgated Invalid Signature
```

with an empty `codeSigningID`, which reads exactly like a broken signature and
is nothing of the sort. The signature is fine. The entitlement is not
authorised, so nothing about the binary is trusted.

So the permission moves to the driver instead, as
`com.apple.developer.driverkit.allow-any-userclient-access`, which is what
Apple's own DriverKit sample project suggests for precisely this reason. The
cost is real but bounded: any app on the machine may open the user client,
rather than one named app. On a machine where you have deliberately installed a
driver you built yourself, that is an acceptable trade.

Both entitlements files carry the reasoning inline, along with the exact snippet
to swap back if the grant ever arrives.

## 3. Register every Mac

Devices ▸ + ▸ macOS. It wants a name and the Provisioning UDID, which is not the
serial number and not the hardware UUID:

```bash
system_profiler SPHardwareDataType | grep -i "Provisioning UDID"
```

Register **every Mac the app will be launched on**. Signing works anywhere;
launching only works on a machine named in the profile. If you build on a laptop
and run on a headless mini, that is still only one machine to register, but
register both if you want to run it in both places, because adding one later
means regenerating the profiles and rebuilding.

You get 100 macOS devices a year, and they can only be removed at renewal, so
there is no reason to be sparing.

## 4. Two provisioning profiles

Profiles ▸ +.

**For the driver:** profile type **DriverKit App Development**, under
Development. Then the driver's App ID, your Apple Development certificate, and
every device you registered.

**For the app:** profile type **macOS App Development**. Same certificate, same
devices, the app's App ID.

Name them something you will recognise, generate, download both.

One thing that will catch you: **a profile is a snapshot.** Enable a capability
on an App ID after generating a profile from it and the existing profile does
not learn about it. You have to regenerate. There is no warning, the profile
simply grants less than you think, and the failure comes back as the
`Taskgated Invalid Signature` above.

## 5. Drop them in

Exact names, next to the Makefile:

```bash
mv ~/Downloads/<driver profile>.provisionprofile ReDrobo/DroboDext.provisionprofile
mv ~/Downloads/<app profile>.provisionprofile    ReDrobo/ReDrobo.provisionprofile
```

The build embeds them on its own and says so. `.gitignore` already excludes
`*.provisionprofile`, and it should stay that way: a profile is a readable plist
inside a signature wrapper, carrying your team name (your legal name, on an
individual account), your team ID, your certificates and the UDID of every Mac
you registered.

## 6. Check them before you build

Five seconds, and it catches every mistake in the preceding five sections:

```bash
security cms -D -i ReDrobo/DroboDext.provisionprofile | plutil -p - | \
  grep -E 'application-identifier|driverkit|ProvisionedDevices|ExpirationDate' -A 4
```

You are looking for four things:

1. `application-identifier` is `<TEAMID>.your.driver.bundle.id`, matching
   `CFBundleIdentifier` in `DroboDext/Info.plist` exactly
2. all three `com.apple.developer.driverkit*` keys are present
3. `ProvisionedDevices` contains this Mac's Provisioning UDID
4. `ExpirationDate` is about a year out

Same again for `ReDrobo.provisionprofile`, where you want
`com.apple.developer.system-extension.install` and nothing exotic.

## 7. Build

```bash
cd ReDrobo && make doctor
```

The development profiles should both report present rather than MISSING. Then:

```bash
cd ReDrobo && make bump && make
```

`make bump` is not optional. Reinstalling a driver whose version has not changed
leaves `sysextd` with two entries for the same identifier, one stuck in
`terminating_for_upgrade_via_delegate`, and activation then fails with a Fault
that looks like a code problem and is not.

The build prints `==> embedded DroboDext.provisionprofile in the dext` and the
equivalent for the app. If it does not, they are in the wrong place or named
wrongly, and it will tell you that too.

Then the check that matters. What you sign has to be a subset of what the
profile grants, and the easiest way to be sure is to look at both:

```bash
codesign -d --entitlements - --xml ReDrobo.app/Contents/Library/SystemExtensions/*.dext \
  2>/dev/null | plutil -p -
```

Three `driverkit` keys, matching the three in the profile. Any key here that is
not in the profile is a SIGKILL waiting to happen.

## 8. Install and activate

```bash
cd ReDrobo && make install
```

macOS refuses to activate an extension from an app outside `/Applications`, so
this step is not negotiable. Building on one Mac and running on another is
fine: `make dist` produces a zip and prints the exact sequence to run at the
other end, including the two things that will otherwise bite (`ditto` merges
into an existing directory instead of replacing it, and `codesign` refuses any
bundle carrying `com.apple.FinderInfo`).

Open the app, press **Install driver**, approve under System Settings ▸ General
▸ Login Items & Extensions ▸ Driver Extensions, then **restart the Mac**.

```bash
systemextensionsctl list
```

`activated enabled` means `sysextd` accepted it. It does **not** mean the
driver is running: the list shows the newly installed version as current while
the kernel keeps executing the old binary until a reboot. The real check is the
driver saying so itself:

```bash
log show --predicate 'sender CONTAINS "DroboDext"' --info --last 30m | grep started
```

`DroboDext: started, build N`, with N being the build you just installed, is the
only proof that counts.

## When it goes wrong

| Symptom | Cause |
|---|---|
| App dies instantly, `Taskgated Invalid Signature`, empty `codeSigningID` | Signed with an entitlement the profile does not grant. Compare the two as in step 7. Regenerate the profile if you enabled a capability after making it. |
| App dies instantly and the profile looks right | This Mac is not in `ProvisionedDevices`. Register it, regenerate both profiles, rebuild. |
| `OSSystemExtensionErrorExtensionNotFound` | The bundle directory name, `CFBundleIdentifier` and `CFBundleExecutable` are not all the same string. |
| Activation fails with a Fault from `activateDecision` | Same version reinstalled. `make bump`, and `systemextensionsctl reset` to clear the jam, which needs SIP off. |
| `activated enabled` but the app finds no driver | It loaded but did not match. The app prints the enclosure's `Vendor Identification` and `Product Identification`; add a personality for them. |
| `DK: family entitlements check failed` | The driver is missing `com.apple.developer.driverkit.family.scsicontroller`, or is signed against a profile that does not grant it. |
| Everything worked, then stopped a year later | The profile expired. Regenerate, rebuild, reinstall. |

## What this does not get you

Distribution. A development profile authorises the Macs listed in it and no
others, so the build you just made is of no use to anybody else, and handing
them the binary will only earn them an instant crash.

A build that installs on a Mac you have never seen needs the *managed*
counterparts of these same capabilities, granted by Apple on request, plus a
Developer ID certificate, Developer ID provisioning profiles and notarization.
The build system already knows how:

```bash
make RELEASE=1 notarize
```

and will refuse until the profiles exist. Requesting the capabilities is done
from the App ID's **Capability Requests** tab in the portal, and
[DRIVERKIT.md](DRIVERKIT.md) covers what to ask for and what to expect.

The other thing to know before you rely on any of this: a development profile
lasts a year, tied to your Apple Development certificate, and stops working the
day it expires. A notarized Developer ID build, by contrast, keeps running for
as long as its certificate was valid on the day it was signed, which is why it
is worth doing before a membership lapses rather than after.
