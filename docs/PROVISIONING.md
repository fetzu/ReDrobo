# Signing ReDrobo yourself

How to get macOS to load the driver without touching a single security setting:
SIP on, no boot-args, the Mac exactly as Apple shipped it. This is route A from
[TESTING.md](TESTING.md), written out in full, because the developer portal is
where all the traps are and not one of them announces itself.

An hour the first time, and almost all of it is self-serve. One capability has
to be requested from Apple, and [section 2](#2-the-userclient-trap) is the way
round it while you wait. Nothing else needs anybody's approval, and none of it
is gated on the DriverKit entitlement request that the rest of the internet will
tell you is mandatory. That one is mandatory for distribution, which is
[a different section](#what-this-does-not-get-you).

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
| `ReDrobo/ReDrobo.entitlements` | the driver's identifier, in the `userclient-access` array |

A find and replace of `org.redrobo` covers all of it.

## 1. Two App IDs

Certificates, Identifiers & Profiles ▸ Identifiers ▸ + ▸ App IDs ▸ App. Explicit
bundle ID, not wildcard. Do it twice.

**For the app**, tick:

- **System Extension**
- **DriverKit UserClient Access**, with the driver's bundle ID in the UserClient
  Bundle IDs field. This is the managed one: it appears on the App ID only once
  Apple has granted it, and [section 2](#2-the-userclient-trap) is what to do
  until then.

**For the driver**, tick:

- **DriverKit (development)**
- **DriverKit Family SCSIController (development)**

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
- **DriverKit Communicates with Drivers.** It reads like **DriverKit UserClient
  Access** and is a separate row, which a granted account shows alongside it.
  Step 6 decodes the profile and settles which key you actually got:
  `userclient-access` is the one the app is signed with.
- **DriverKit PCI (development).** Self-serve, and not this driver either.
- Everything else. A capability you do not sign against is a capability that
  cannot fail.

## 2. The UserClient trap

The tight arrangement is `com.apple.developer.driverkit.userclient-access` on
the **app**, naming the driver, so that exactly one app may open the user
client. That is what both entitlements files carry today, and it is the one
thing on this page you cannot simply tick.

**DriverKit UserClient Access** is the row with no "(development)" suffix and no
"Development only" note, which makes it **managed**: Apple grants it by hand, on
request, and until they do it cannot appear in a profile you made yourself.
[Asking for it](#asking-for-them) is at the bottom of this page. For this
project it took three weeks.

That matters because of how AMFI works. Sign a binary with a restricted
entitlement its embedded profile does not grant and the process is SIGKILLed the
instant it execs. The crash report says:

```
Namespace CODESIGNING, Code 1, Taskgated Invalid Signature
```

with an empty `codeSigningID`, which reads exactly like a broken signature and
is nothing of the sort. The signature is fine. The entitlement is not
authorised, so nothing about the binary is trusted.

### While you wait

The permission can move to the driver instead, as
`com.apple.developer.driverkit.allow-any-userclient-access`, which is what
Apple's own DriverKit sample project suggests for precisely this reason. It is
self-serve, **DriverKit Allow Any UserClient (development)** in the portal, and
it is what this repo shipped for as long as the request was pending. The cost is
real but bounded: any app on the machine may open the user client, rather than
one named app. On a machine where you have deliberately installed a driver you
built yourself, that is an acceptable trade.

Two edits, and they go together:

- in `ReDrobo/ReDrobo.entitlements`, delete the
  `com.apple.developer.driverkit.userclient-access` key and the array under it
- in `DroboDext/DroboDext.entitlements`, add
  `com.apple.developer.driverkit.allow-any-userclient-access` set to `<true/>`,
  where the comment says it used to be

Then tick **DriverKit Allow Any UserClient (development)** on the driver's App
ID instead of **DriverKit UserClient Access** on the app's, and carry on with
section 3.

This route runs out at distribution. The portal offers no non-development
counterpart, so no Developer ID profile will carry the key and a build signed
this way is refused by the notary service. It gets you every Mac you have
registered and not one more, which is the same limit development profiles have
anyway.

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

Two `driverkit` keys, `driverkit` and `family.scsicontroller`, matching two of
the ones in the profile. Then the app, which should carry
`system-extension.install` and `userclient-access` naming the driver:

```bash
codesign -d --entitlements - --xml ReDrobo.app | plutil -p -
```

The profile may grant more than the binary claims and that is fine. A key on the
binary that the profile does not grant is a SIGKILL waiting to happen.

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

and will refuse until the profiles exist.

### Asking for them

Identifiers, the App ID, the **Capability Requests** tab, Request. Account
Holder role only, and the App ID has to exist first.

Two requests, because `userclient-access` is an app-side entitlement and lives
on the app's App ID rather than the driver's:

| On | Which DriverKit entitlements do you need? | UserClient Bundle IDs |
|---|---|---|
| the driver's App ID | DriverKit, DriverKit Family SCSIController | the driver's bundle ID |
| the app's App ID | UserClient Access | the driver's bundle ID |

Nothing to request for `com.apple.developer.system-extension.install`. System
Extension is an ordinary capability you tick.

Ask for UserClient Access rather than Allow Any UserClient. It is the tighter of
the two, it is the arrangement the entitlements files want to go back to, and
leading with the loose one makes the whole request look worse than it is. Fall
back to Allow Any UserClient only if the tight one is refused.

In the description, say what the driver does and does not do: read-only,
`MODE SENSE(10)` on the vendor page, standard opcodes, never the vendor-specific
range, matching on `IOSCSIPeripheralDeviceNub` rather than by USB vendor and
product ID. Say plainly that you are not the hardware vendor and that Drobo was
liquidated in 2023. Apple's DTS has said on the record that they approve
requests from third parties and lean towards approving rather than refusing, so
the honest version of the story is also the strong one. Point at a driver that
already loads and reads, which is a better letter than a proposal.

**If the Request button lands on a 404**, and it may: it links to
`developer.apple.com/contact/request/system-extension/`, which Apple retired
without updating the link, and the same dead link is still in Apple's own
DriverKit documentation and on their System Extensions page. It is not
necessarily broken for you. Try another browser first, signing in at
`developer.apple.com/account` before navigating rather than following a
bookmark: this was a 404 in one browser and the working form in Safari on the
same machine, the same afternoon. If it survives that, Apple's own escalation
for it is developer.apple.com/contact, then Development and Technical, then
Entitlements, which is free and does not consume a code-level support incident.

Expect weeks. Status and any notes from Apple come back on the same Capability
Requests tab.

### Once they are granted

Nothing arrives in the post: the capabilities simply turn up on the App IDs, and
everything from there is the same portal work as above with different words on
the buttons.

1. **Tick the granted rows.** On the driver's App ID, **DriverKit** and
   **DriverKit Family SCSI Controller**, the two without the "(development)"
   suffix. On the app's, **DriverKit UserClient Access**, with the driver's
   bundle ID in the UserClient Bundle IDs field. Leave the development rows
   ticked; they do not conflict, and the development profiles still want them.
2. **Regenerate the development profiles too**, not only the new ones. A profile
   is a snapshot, and the app is signed with `userclient-access` now, which a
   profile generated before the grant does not carry. Same SIGKILL as ever, on
   your own Mac this time.
3. **Two more profiles**, Profiles ▸ +, under Distribution rather than
   Development: the Developer ID type, once for each App ID, taking whichever
   DriverKit variant of it the portal offers for the driver. Neither carries a
   device list, which is the entire point of them. Download both and drop them
   next to the Makefile as `ReDrobo-DeveloperID.provisionprofile` and
   `DroboDext-DeveloperID.provisionprofile`, exactly those names.
4. **Store the notary credentials once.** They live in the keychain and never in
   the repo:

   ```bash
   xcrun notarytool store-credentials redrobo
   ```

   It asks for a profile name, which is what `redrobo` is here, your Apple ID,
   the team ID, and an app-specific password made at appleid.apple.com. Pass
   `NOTARY_PROFILE=` to the Makefile if you name it something else.

5. **Build it:**

   ```bash
   cd ReDrobo && make doctor && make bump && make RELEASE=1 notarize
   ```

`make doctor` reports both sets of profiles and both identities, and the release
set should stop saying MISSING. Then `notarize` submits the zip, waits, staples
the ticket to the app, validates it, runs `spctl` against it and writes
`ReDrobo-app.zip`. A few minutes, most of it Apple's.

Verify it somewhere honest. Not this Mac, and not any Mac registered under
Devices or carrying a development build: those all have reasons to accept the
app that a stranger's machine will not have. A Mac with SIP on that has never
seen this project is the only run that proves anything.

### Releasing from CI

Once that works by hand, [.github/workflows/release.yml](../.github/workflows/release.yml)
does the same thing on a tag: bump the version, commit, push `v1.2.3`, and it
builds, signs, notarizes, staples and publishes a pre-release with the zip
attached. It runs on `macos-26`, whose default Xcode is 26.6 with DriverKit
25.5, the same toolchain this was developed against.

It needs seven secrets, made once, in a repository **environment** called
`release`: Settings ▸ Environments ▸ New environment, then add them there rather
than as plain repository secrets, so the job can be put behind a review.

**The certificate.** Keychain Access, and specifically the **My Certificates**
tab rather than All Items or Certificates: only that category pairs a
certificate with its private key, and a `.p12` is exactly that pair, so the
format stays greyed out anywhere else. Find *Developer ID Application*, select
the row with the disclosure triangle, File ▸ Export Items, Personal Information
Exchange (.p12). It asks for the login keychain password to release the key,
then for a password to protect the file. Export that one row, not all your
identities, and give it a real password.

```bash
base64 -i DeveloperID.p12 | pbcopy      # -> DEVELOPER_ID_CERT_P12
```

and the password itself goes in `DEVELOPER_ID_CERT_PASSWORD`. Delete the `.p12`
afterwards or keep it somewhere you would keep a house key, because that is
what it is: whoever holds it and the password signs as you.

**The two profiles**, the same files the Makefile already uses:

```bash
base64 -i ReDrobo/ReDrobo-DeveloperID.provisionprofile | pbcopy   # -> PROFILE_APP_DEVELOPER_ID
base64 -i ReDrobo/DroboDext-DeveloperID.provisionprofile | pbcopy # -> PROFILE_DEXT_DEVELOPER_ID
```

**The notary credentials.** An app-specific password is tied to your Apple ID
and cannot be scoped, so CI gets an App Store Connect API key instead:
appstoreconnect.apple.com ▸ Users and Access ▸ Integrations ▸ App Store Connect
API ▸ Team Keys ▸ +. Access **Developer** is enough to notarize; if notarytool
answers 403, raise it to App Manager. The `.p8` downloads exactly once and is
never offered again.

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # -> NOTARY_KEY_P8
```

`NOTARY_KEY_ID` is the Key ID from that table and `NOTARY_ISSUER_ID` the Issuer
ID above it. The Makefile takes these three as `NOTARY_KEY`, `NOTARY_KEY_ID` and
`NOTARY_ISSUER`, and falls back to the keychain profile when they are unset, so
your own `make RELEASE=1 notarize` is unaffected.

Run the workflow by hand from the Actions tab first. Without a tag it builds and
notarizes and stops, leaving the zip as a run artifact, which is how to test a
change to it without publishing anything.

The release it makes is a **pre-release**, deliberately. CI has never seen an
enclosure, so what comes out is correctly signed and completely unproven.
Install it next to a Drobo, check the driver starts and reads, and only then
promote it.

The other thing to know before you rely on any of this: a development profile
lasts a year, tied to your Apple Development certificate, and stops working the
day it expires. A notarized Developer ID build, by contrast, keeps running for
as long as its certificate was valid on the day it was signed, which is why it
is worth doing before a membership lapses rather than after.
