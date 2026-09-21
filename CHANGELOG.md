# Changelog

All notable changes to ReDrobo are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versioning is
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Written after the fact, from the git history and the release notes, so the
three versions below are a reconstruction rather than a log kept as the work
happened.

## [Unreleased]

### Changed

- Both GitHub actions moved to v7 (checkout and upload-artifact), which stops
  the runners warning about a Node version they were force-upgrading anyway.
  Still pinned by commit rather than by tag, because a tag can be moved and a
  commit cannot.

No further development is planned, so this section may stay quiet for a while:
see [Project status](README.md#project-status).

## [1.2.0] - 2026-09-10

The first build anybody can install. Developer ID signed, notarized and
stapled, so it loads on a Mac in the state Apple shipped it: SIP on, no
boot-args, no developer account, nothing to sign yourself.

### Added

- Releases build on GitHub Actions
  ([.github/workflows/release.yml](.github/workflows/release.yml)): push a
  `v1.2.3` tag and the job signs, notarizes, staples and publishes. It runs on
  `macos-26`, the image whose Xcode matches the toolchain the driver was proven
  against, and it publishes a pre-release, because nothing in CI has ever seen
  an enclosure.
- `notarytool` takes an App Store Connect API key in CI and the keychain
  profile locally, so `make RELEASE=1 notarize` by hand is unchanged.
- An Installing section in the README, since the caveats pointed at a releases
  page and nothing told anybody arriving there what to do with the zip.

### Changed

- The permission to open the user client moves back where it belongs:
  `userclient-access` on the app, naming the driver, rather than
  `allow-any-userclient-access` on the driver. The user client goes from
  openable by anything on the machine to openable by one named app. Apple
  granted the managed DriverKit, DriverKit Family SCSIController and UserClient
  Access capabilities on 2026-09-10, three weeks after they were requested, with
  no questions and no conditions.
- The driver's deployment target drops from DriverKit 25.5 to 25.0, so it loads
  on macOS 26.0 through 26.4 where it would previously have refused. It is a
  deployment target and not the SDK, and 25.5 quietly meant macOS 26.5 or newer,
  which is the wrong end of the range for the Intel Macs this is for.

### Fixed

- `make doctor`'s guard against a development profile hiding under a release
  filename read `ProvisionsAllDevices` by grepping `plutil -p` output for
  `=> 1`. It prints `=> true`, so the guard rejected both of the real Developer
  ID profiles instead. Extracting the key is one call and does not care how it
  is displayed.

### Removed

- `com.apple.developer.driverkit.allow-any-userclient-access`, which was only
  ever a stand-in while the tight capability was pending, and which has no
  distribution counterpart in the portal anyway.

## [1.1.0] - 2026-08-20

Source only, and for a better reason than the previous release: a development
profile authorises the Macs listed in it and no others, so a binary from here
would not have run for you.

### Added

- [docs/PROVISIONING.md](docs/PROVISIONING.md): the developer portal end of it
  step by step, including the bundle identifier rules, the UserClient trap and
  a symptom-to-cause table.
- A Developer ID and notarization path in the build. `RELEASE=1` switches the
  identity, the profiles and the timestamp in one go, and `make notarize` zips,
  submits, staples and rebuilds the archive (a zip cannot carry a ticket, and
  the copy inside the one submitted has none). Waiting, at this point, on the
  distribution capabilities being granted.
- `make doctor` reports the development and release signing paths separately.

### Changed

- Signing against a provisioning profile becomes the documented route, and SIP
  no longer has to come off. The DriverKit capabilities this driver needs turn
  out to be self-serve for development: they are checkboxes on the App ID page,
  granted to anybody who ticks them. Confirmed on 2026-08-20 on a MacBook Pro
  running macOS 26.6.2, SIP enabled and no boot-args at all: installed,
  activated, matched a Drobo 5D and read it. Which contradicts the usual claim
  that a driver extension must be notarized once SIP is on (true of a Developer
  ID build, not of a development one signed against a profile naming the
  machine).
- The user client permission moved onto the driver as
  `allow-any-userclient-access`, because the tighter `userclient-access` is
  managed by Apple and cannot go into a profile you made yourself. Looser than
  wanted, acceptable on a machine where you installed the driver yourself, and
  both entitlements files carry the reasoning and the snippet to swap back.
- The setup assistant offers the two routes rather than assuming the second,
  and hides the SIP and AMFI steps entirely on a build that carries a profile.
- Release builds no longer pass `--timestamp=none`: Gatekeeper checks that the
  certificate was valid on the day of signing, the secure timestamp is what
  proves when that was, and the notary service refuses anything signed without
  one. Development builds keep skipping it, it costs a round trip to Apple every
  time.
- [docs/TESTING.md](docs/TESTING.md) restructured around the two routes, and
  the README caveats rewritten: "it will not run on a normal Mac" was simply
  wrong.

## [1.0.0] - 2026-08-19

First release, source only. Drobo Dashboard cannot run on macOS 26 (Intel-only,
and it needs a kext nobody can sign any more), so this replaces the management
side of it with a userspace driver speaking the same vendor mode pages.

### Added

- `DroboDext`, a DriverKit driver extension matching on
  `IOSCSIPeripheralDeviceNub` and reading Drobo ESA management records with
  `MODE SENSE(10)` on vendor mode page `0x3A`, with the volume mounted
  throughout. 26 Vendor/Product personalities, taken from the pairs Drobo's own
  kext matched on.
- `ReDrobo.app`: capacity against the enclosure's own yellow and red
  thresholds, the drive bays with model, size, health, errors, serial, firmware
  revision and wear, the status word decoded bit by bit, a menu bar item, and
  notifications when something changes rather than when something merely is.
- Read-only by design. `MODE SELECT(10)` is decoded and deliberately not
  implemented.
- [docs/PROTOCOL.md](docs/PROTOCOL.md), the management protocol field by field,
  with every claim rated confirmed / high confidence / open;
  [docs/DRIVERKIT.md](docs/DRIVERKIT.md),
  [docs/TESTING.md](docs/TESTING.md),
  [docs/WRITING.md](docs/WRITING.md) and
  [docs/TEARDOWN.md](docs/TEARDOWN.md).
- `tools/`: `drobo-space.py` (the real free space with no driver at all),
  `droboesa` and `droboprobe` (the capture and probe utilities the protocol was
  recovered with), `decode-esa.py` and `check-dext.sh`.
- `make check`, the offline checks over the record decoding, the status word
  tables and the redundancy derivation. No hardware needed.

Tested against a Drobo 5D on firmware 4.2.3, which is still the only enclosure
any of this has ever met.

[Unreleased]: https://github.com/fetzu/ReDrobo/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/fetzu/ReDrobo/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/fetzu/ReDrobo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/fetzu/ReDrobo/releases/tag/v1.0.0
