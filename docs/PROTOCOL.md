# The Drobo "ESA" management protocol

The command shape was recovered by static analysis of
`TrustedDataSCSIDriver.kext` 1.9.1 (Drobo Dashboard 3.6.1, build 115880,
Feb 2021), cross checked against `DDService64d` and the Drobo 5D firmware image
`release.Drobo5D.4-2-3.tdf`.

The record layouts were then **confirmed against a live Drobo 5D** on
2026-08-19, firmware 4.2.3, and every decoded value agreed with what Drobo
Dashboard displayed at the same moment. See
[Validation status](#validation-status) for what is settled and what is not.

## Summary

The Drobo management channel is **not** a proprietary transport. It is
ordinary SCSI:

| | |
|---|---|
| Read a record | `MODE SENSE(10)`, opcode `0x5A` |
| Write a record | `MODE SELECT(10)`, opcode `0x55` |
| Mode page | `0x3A` (vendor-defined) |
| Record selector | the **sub-page code** byte |

That single fact is what makes a modern, kext-free reimplementation possible.
Both opcodes are standard SPC commands, so they are reachable from Apple's
supported userspace SCSI paths, and they do **not** fall in the
vendor-opcode range (`0xC0`–`0xFF`) that DriverKit requires exclusive access for.

## Where this comes from

Two sources, and it is worth keeping them apart.

The **command shape** came from `TrustedDataSCSIDriver.kext`, which ships with a
debug symbol table. The **record layouts** below came from `DDService64d`, the
daemon that sits between the kext and Dashboard. That binary is a fully
symbolicated C++ build with an `ESAProtocol::` namespace containing a
`parse()`, `generate()` and `print()` for every record type, and the `print()`
functions carry the field names as format strings. So most of what follows is
not inference: it is Drobo's own struct layout read back out of their own code.

Which parts are confirmed against a live enclosure and which are only read out
of the binary is tracked in [Validation status](#validation-status). The
distinction matters: a layout recovered from `parse()` is very likely right, but
nobody here has a 5D that answers sub-page `0x35` to prove it.

## Where the command shape comes from

`TrustedDataSCSIDriver.kext` ships with a full debug symbol table, so the
user-client API is recoverable directly:

```
com_TrustedData_UserClient_SCSIType00::sOpen
com_TrustedData_UserClient_SCSIType00::sClose
com_TrustedData_UserClient_SCSIType00::sGetESAModePage
com_TrustedData_UserClient_SCSIType00::sSetESAModePage
com_TrustedData_UserClient_SCSIType00::sVendorSpecificIn
com_TrustedData_UserClient_SCSIType00::sVendorSpecificOut
com_TrustedData_UserClient_SCSIType00::sVendorSpecificPassThroughIn
com_TrustedData_UserClient_SCSIType00::sVendorSpecificPassThroughOut
com_TrustedData_UserClient_SCSIType00::sataReadCommandMethod
com_TrustedData_UserClient_SCSIType00::sataWriteCommandMethod
com_TrustedData_UserClient_SCSIType00::sSetLoggingLevel
```

Every one of these funnels into a single CDB builder:

```cpp
com_TrustedData_driver_VendorSpecificType00::CREATE_CDB(
    OSObject            *request,
    IOMemoryDescriptor  *buffer,
    unsigned char        REQUEST_CODE,        // opcode
    unsigned char        dataTransferDirection,
    unsigned char        LLBAA,               // validated <= 1
    unsigned char        DBD,                 // validated <= 1
    unsigned char        PC,                  // validated <= 3
    unsigned char        PAGE_CODE,           // validated <= 0x3F
    unsigned char        SUB_PAGE_CODE,       // validated <= 0xFF
    unsigned short       ALLOCATION_LENGTH,
    unsigned char        CONTROL)
```

The parameter names come from the driver's own `IOLog` validation messages
(`"CREATE_CDB bad LLBAA()"`, `"CREATE_CDB bad PAGE_CODE()"`, …).

## CDB layout

Disassembling `CREATE_CDB` shows the byte assembly:

```asm
shlb  $0x4, %r14b          ; LLBAA << 4
shlb  $0x3, %bl            ; DBD   << 3
orb   %r14b, %bl           ; byte1 = (LLBAA<<4) | (DBD<<3)
movb  0x18(%rbp), %al      ; PC
shlb  $0x6, %dl            ; PC << 6
orb   0x20(%rbp), %dl      ; byte2 = (PC<<6) | PAGE_CODE
movw  0x30(%rbp), %ax      ; ALLOCATION_LENGTH, split hi/lo
callq IOSCSIPrimaryCommandsDevice::SetCommandDescriptorBlock(...)
```

which is exactly the SPC `MODE SENSE(10)` / `MODE SELECT(10)` shape:

```
byte 0   opcode              0x5A (sense) / 0x55 (select)
byte 1   (LLBAA<<4)|(DBD<<3)
byte 2   (PC<<6)|PAGE CODE
byte 3   SUBPAGE CODE
byte 4   0
byte 5   0
byte 6   0
byte 7   ALLOCATION LENGTH (MSB)
byte 8   ALLOCATION LENGTH (LSB)
byte 9   CONTROL
```

The driver also emits an error string `MODE_SELECT_10_EXTENDED`, confirming the
same builder is reused for the write path.

## The call site

`GetModePage(unsigned char pageNum, _ESAModePageStruct &, unsigned short &)`
sets up the call like this:

```asm
movl  $0x5a, %ecx      ; REQUEST_CODE          = MODE SENSE(10)
movl  $0x2,  %r8d      ; dataTransferDirection = kSCSIDataTransfer_FromTargetToInitiator
movl  $0x0,  %r9d      ; LLBAA                 = 0
pushq %r10             ; CONTROL               = 0
pushq %rax             ; ALLOCATION_LENGTH     = *(uint16_t*)&structSize
pushq %rbx             ; SUB_PAGE_CODE         = pageNum
pushq $0x3a            ; PAGE_CODE             = 0x3A
pushq %r10             ; PC                    = 0
pushq %r10             ; DBD                   = 0
```

So the wire command for reading ESA record `pp` with allocation length `LLLL` is:

```
5A 00 3A pp 00 00 00 LL LL 00
```

`SetModePage` is byte-for-byte identical except `movl $0x55, %ecx`.

Note the allocation length is read as a `uint16_t` from the **front of the
caller's struct** — i.e. `_ESAModePageStruct` begins with its own size field.

## ESA record map

Sub-page numbers come from the jump table in `getESAModePage`. The layouts
below were recovered on 2026-08-19 from a live Drobo 5D (fw 4.2.3), captured
with `tools/droboesa` and decoded with `tools/decode-esa.py`, then checked
field by field against what Dashboard displayed at the same moment.

### Response framing

Every record comes back as a standard SPC sub-page mode page:

```
byte 0   0x7A        PS=0, SPF=1, PAGE CODE = 0x3A
byte 1   sub-page    the record number you asked for
byte 2   length hi   big endian page length, excluding these 4 bytes
byte 3   length lo
byte 4+  payload
```

The kext strips the mode parameter header and any block descriptor, so what the
user client hands back starts directly at the page. Field offsets below are
counted from byte 0, so the payload always begins at `0x04`.

**Endianness: the payload is big endian**, as SCSI should be. This matters
because the kext reads these fields with x86 little endian loads, so its own
`IOLog` lines print nonsense for anything wider than a byte. Its *offsets* are
authoritative, its printed values are not. Drobo evidently never looked at that
debug output.

### The records

| Sub-page | Name | Field | Offset | Type | Observed |
|---:|---|---|---:|---|---|
| `0x01` | ConfigInfo | slots | `0x04` | u8 | 6 |
| | | maxLuns | `0x06` | u8 | 16 |
| `0x02` | CapacityInfo | free | `0x04` | u64 | 1 294 882 336 768 |
| | | used | `0x0C` | u64 | 4 667 223 805 952 |
| | | total | `0x14` | u64 | 5 962 106 142 720 |
| `0x03` | SlotInfo | slots | `0x04` | u8 | 6 |
| | | entries | `0x05` | 72 bytes each | see below |
| `0x04` | LunInfo | luns | `0x04` | u8 | 1 |
| | | total | `0x08` | u64 | 5 962 106 142 720 |
| | | used | `0x10` | u64 | 4 667 223 805 952 |
| `0x05` | SystemSettings | currentTime | `0x04` | u32 | **local** wall clock, not UTC |
| | | gmtOffset | `0x08` | u16 | minutes east, 120 = UTC+2 |
| | | name | `0x0A` | string | `RAIDDEADREDEMPTION` |
| `0x06` | ProtocolVersion | major.minor | `0x04`, `0x05` | u8, u8 | 0.11 |
| `0x08` | FirmwareInfo | major | `0x04` | u8 | 7 |
| | | minor | `0x05` | u8 | 199 |
| | | build | `0xCE` | u32 | 116068 |
| | | build date | `0x0A` | string | `Apr 16 2021,00:20:00` |
| | | platform | `0x2A` | string | `ArmMarvell` |
| | | version | `0x3A` | string | `4.2.3` |
| `0x09` | StatusInfo | status | `0x04` | u32 | `0x00028000` when healthy |
| | | relayoutCount | `0x08` | u32 | 0 |
| `0x30` | Options | yellowThreshold | `0x04` | u8 | 85 (percent) |
| `0x31` | Options2 | featureOnOffStates | `0x04` | u64 | `0x0000000000000003` |

Sub-page `0x07` is absent from the kext's dispatch table and should be expected
to fail, even though `ESALUNInfo2` claims it.

### The full record map

`ESAProtocol` implements far more than the ten records the kext's jump table
exposes. Each class names its own sub-page in `getSubPageType()`:

| Sub-page | Class | What it is |
|---:|---|---|
| `0x01` | `ESAConfigurationInfo` | slot and LUN maxima, demo mode |
| `0x02` | `ESACapacityInfo` / `ESACapacityInfoPT` | capacity, seven fields (below) |
| `0x03` | `ESASlotInfo` | drive bays, 72 bytes per slot |
| `0x04` | `ESALUNInfo` | volumes |
| `0x05` | `ESASystemSettings` | clock, GMT offset, name |
| `0x06` | `ESAProtocolVersion` | major.minor |
| `0x07` | `ESALUNInfo2` | volumes, extended |
| `0x08` | `ESAFirmwareInfo` | version, build, platform |
| `0x09` | `ESAStatusInfo` | status word and disk pack status |
| `0x0A`–`0x0D` | `ESASetCHAP`, `ESASetSingleInitiator`, `ESASetUsedCapacity`, `ESASetLUNName` | write-side, iSCSI |
| `0x10` | `ESASnapshotInfo` | snapshots |
| `0x11` | `ESADiskPackInfo` | pack name, ID, generation, flags |
| `0x12` | `ESADeviceInquiry` | — |
| `0x15` | `ESALUNMappingInfo` | LUN mapping |
| `0x30` | `ESAOptions` | thresholds, data check settings |
| `0x31` | `ESAOptions2` | feature states, spin down delay |
| `0x32` | `ESAModePageB1200NetworkInterfaces` | B1200i only |
| `0x33` | `ESASystemInfo` | three u32, unnamed |
| `0x34` | `ESASystemPerformance` | — |
| `0x35` | `ESASlotInfo2` | **drive bays, extended: health, serial, temperature** |
| `0x36` | `ESAPowerSupply` | — |
| `0x37` | `ESAFanInfo` | — |
| `0x38` | `ESAControllerCard` | — |
| `0x39` | `ESAExpanderInfo` | — |
| `0x3A` | `ESABatteryInfo` | — |
| `0x80` | `ESADeviceSerial` / `ESAEventMessages` | enclosure serial; also claimed by the event log |
| `0x82` | `ESAGetKernelInterfaceInfo` | — |

The entries marked `—` have a `print()` with no format strings, so their fields
are unnamed. They are not read by ReDrobo.

`0x80` is claimed by two classes. ReDrobo asks for it and only believes the
answer if it looks like a serial number, which `ESADeviceSerial::parse` itself
does: it checks for a leading `D`, `R`.

### SlotInfo2, sub-page `0x35` — the interesting one

**Confirmed on hardware 2026-08-19**: a Drobo 5D on firmware 4.2.3 answers this
record, and every field below decodes correctly against it.

This is where per-disk health, serial numbers, firmware revisions and
temperature live. `getMaximumModePageSize()` returns 1308, the same size as
every other record, which works out as a 12 byte header plus twelve 108 byte
slots.

The live capture confirms the header independently: **byte 9 of the page is
`0x6C`, the entry stride itself**, which agrees with `calculateSize()` without
having to trust it.

```
page + 0x00   0x7A
page + 0x01   0x35
page + 0x02   length, big endian
page + 0x08   slot count
page + 0x0C   first slot entry
```

Each entry is `0x6C` = 108 bytes, per
`ESASlotInfoStruct2::calculateSize`:

| Offset | Type | Field |
|---:|---|---|
| `+0x00` | u8 | slot id |
| `+0x01` | u8 | slot status |
| `+0x02` | u16 | error count |
| `+0x04` | u32 | disk state |
| `+0x08` | u8 | disk type |
| `+0x09` | u8 | temperature |
| `+0x0A` | u8 | life remaining, percent |
| `+0x0B` | u8 | rotational speed |
| `+0x0C` | char[44] | manufacturer and model |
| `+0x38` | char[12] | disk firmware revision |
| `+0x44` | char[24] | disk serial number |
| `+0x5C` | u64 | total capacity |
| `+0x64` | u64 | managed capacity |

Live values from the confirmed capture, for the five hard disks and the mSATA
accelerator of a 5D:

| Field | Hard disks | Accelerator |
|---|---|---|
| slot status | 3 | 3 |
| disk state | `0x10`, or `0x11` on one that had healed | `0x20` |
| disk type | `0` | `4` |
| temperature | `0` | `0` |
| life remaining | `100` | `91` |
| rotational speed | `0` on WD20EZRX, `27` on WD40EFRX / WD20EFRX | `1` |

Three things fall out of that, and all three were got wrong first time:

**Disk type is `0` for a hard disk and `4` for an SSD.** Not 1 and 2.

**Rotational speed is not a substitute for it.** It reads `0` on the WD20EZRX
hard disks and `1` on the SSD, so "no rotation means solid state" labels two
hard disks as SSDs and the actual SSD as a hard disk. It is only safe to read
the type byte.

**Firmware 4.2.3 does not populate temperature.** Every slot reports zero. The
field exists and is named; this firmware simply has nothing to put in it, so a
client must treat zero as absent rather than as freezing.

Life remaining reads `100` on every hard disk, which is a placeholder rather
than a measurement — it is a flash wear metric. The accelerator's `91` is real.

The names are the format strings in `ESASlotInfoStruct2::print`, verbatim:
`"Slot Id: %u"`, `"Slot Status: %d"`, `"Slot Error count: %d"`,
`"Slot disk state: %d"`, `"Slot disk type: %d"`, `"Slot temperature: %d"`,
`"Slot lifeRemaining: %d"`, `"Slot rotationalSpeed: %d"`,
`"Disk Manufacturer: %s"`, `"Disk firmware revision: %s"`,
`"Disk serial number: %s"`, `"Total Capacity: %llu"`,
`"Managed Capacity: %llu"`.

**Disk state** is masked with `0xF` and switched on 0 to 3, from
`DDUtils::GetDiskState`, which maps them to `kUIString_DiskHealth_*`:

| Value | Meaning |
|---:|---|
| 0 | Good |
| 1 | Healed |
| 2 | Warning |
| 3 | Failed |

The upper bits of the u32 are not used by that path and are not decoded. On the
live capture they are `0x10` for the hard disks and `0x20` for the SSD, which
tracks the disk type rather than the health.

Whether an enclosure answers `0x35` at all is itself a firmware feature, bit 1
of the feature table (`DroboDevice::IsSlotInfo2Supported`), so a client has to
cope with it failing.

### The model field carries the interface

Both slot records glue the interface marker onto the end of the model string.
A live 5D reports `"WDC WD20EZRX-00DSATA"` and `"M4-CT128M4SSD3  SATA"`. The
model is everything before `SATA`.

### CapacityInfo has seven fields, not three

**Confirmed**: the live capture declares a page length of `0x38` — 56 bytes,
exactly seven u64s.

`ESACapacityInfoPT::parse` reads seven big endian u64s:

| Offset | Field |
|---:|---|
| `+0x04` | free capacity, protected |
| `+0x0C` | used capacity, protected |
| `+0x14` | total capacity, protected |
| `+0x1C` | **total capacity, unprotected** |
| `+0x24` | free capacity, PT |
| `+0x2C` | used capacity, PT |
| `+0x34` | total capacity, PT |

The three fields decoded earlier are the *protected* set, which is why they
matched Dashboard. The unprotected total is capacity the array is carrying with
no redundancy behind it.

### Options, sub-page `0x30`

`ESAOptions::parse` reads more than the yellow threshold:

| Offset | Type | Field |
|---:|---|---|
| `+0x04` | u8 | yellow alert threshold, percent — live value 85 |
| `+0x05` | u8 | **red alert threshold, percent** — live value 95 |
| `+0x06` | u8 | packed flags: use unprotected capacity, realtime data check, background data check type |

### Options2, sub-page `0x31`

| Offset | Type | Field |
|---:|---|---|
| `+0x04` | u64 | `featureOnOffStates` — live value `0x3` |
| `+0x0C` | u16 | spin down delay — live value 14 minutes |
| `+0x0E`… | u32 | direct-attach iSCSI address and mask |

### DeviceSerial, sub-page `0x80`

Four byte header then a 24 byte string; `getMaximumModePageSize()` returns 28.
`ESADeviceSerial::parse` sanity-checks the first two characters as `D` and `R`,
which matches the `DRB…` format Dashboard displays.

### SlotInfo entries

A one byte count at `0x04`, then that many 72 byte entries starting at `0x05`.
Six entries on a 5D: the five drive bays, then the mSATA accelerator.

```
entry + 0x03   u64      capacity in bytes
entry + 0x14   text     vendor and model, space padded, followed by "SATA"
```

Live example, which matches Dashboard's bay display exactly:

| Slot | Role | Capacity | Model |
|---:|---|---|---|
| 0 | bay 1 | 2 000 398 934 016 | WDC WD20EZRX-00D |
| 1 | bay 2 | 2 000 398 934 016 | WDC WD20EZRX-00D |
| 2 | bay 3 | 4 000 787 030 016 | WDC WD40EFRX-68N |
| 3 | bay 4 | 2 000 398 934 016 | WDC WD20EFRX-68E |
| 4 | bay 5 | 4 000 787 030 016 | WDC WD40EFRX-68N |
| 5 | mSATA | 128 035 676 160 | M4-CT128M4SSD3 |

The remaining bytes of each entry (per drive status flags, serial number,
firmware revision, which are visible as text further along) are not decoded yet.

### The clock is local time, not UTC

`currentTime` looks like a Unix timestamp and is not one. On 2026-08-19 the
device reported a value decoding to 16:19:07 while real UTC was 14:19:08, on a
host set to UTC+2. The enclosure stores its own wall clock in that field and
keeps the offset separately in `gmtOffset`.

So format it as UTC to print the clock face the Drobo believes in, and do not
convert it. Treating it as a real timestamp puts the device two hours into the
future.

## The status word, decoded

`ESAStatusInfo` (`0x09`) holds two words, not one:

| Offset | Type | Field |
|---:|---|---|
| `+0x04` | u32 | ESA status |
| `+0x08` | u32 | relayout count |
| `+0x0C` | u32 | ESA disk pack status |

### Severity

`ESAAlertHistory::getSeverityForStatus` is four instructions and settles how
Drobo itself decided red, yellow or green:

```asm
testl   $0x14c4187a, %edi           ; any of these -> red
movabsq $0x36002300244, %rax
andq    %rax, %rdi                  ; any of these -> yellow
                                    ; otherwise    -> green
```

Note the red mask is tested 32 bits wide and the yellow mask 64.

The healthy value observed on the live 5D, `0x00028000`, is in neither mask, so
it is green. That is a useful cross-check: the masks were recovered
independently of the capture and they agree with it.

### The individual bits

Recovered from `AlertMailer::GetEventIDForStatus`, which switches on one bit at
a time and names each:

| Bit | Mask | Name |
|---:|---|---|
| 1 | `0x2` | Red threshold exceeded |
| 2 | `0x4` | Yellow threshold exceeded |
| 3 | `0x8` | No disks |
| 4 | `0x10` | Bad disk |
| 5 | `0x20` | Too many missing disks |
| 6 | `0x40` | No redundancy |
| 9 | `0x200` | Relayout in progress |
| 11 | `0x800` | Mismatched disks |
| 18 | `0x40000` | Incompatible disk pack |
| 20 | `0x100000` | Power supply failure |
| 21 | `0x200000` | Fan partial failure |
| 22 | `0x400000` | Fan failure |
| 23 | `0x800000` | Fan missing |
| 25 | `0x2000000` | Hybrid tiering state |
| 32 | `0x100000000` | DroboShare alert |
| 33 | `0x200000000` | Drive added |
| 34 | `0x400000000` | Drive removed |
| 35 | `0x800000000` | Dual disk redundancy updated |
| 36 | `0x1000000000` | Volume usage over limit |
| 37 | `0x2000000000` | All volumes over limit |
| 38 | `0x4000000000` | Target login |
| 39 | `0x8000000000` | Relayout complete |
| 41 | `0x20000000000` | Three SSDs and a disk required |

The two masks corroborate the table: every bit in the red mask is a fault
condition and every bit in the yellow mask is a warning, which is what you would
expect if both were derived from the same enum.

**Bits 15 and 17 are the two set on a healthy array and neither appears in the
alert switch.** They are therefore not alerts, and what they positively mean is
unknown. ReDrobo lists them as set and refuses to name them.

Bit 6, "no redundancy", is the one honest answer to "can this array survive a
disk failure right now". It is a fact the enclosure reports, unlike the
redundancy *level*, which is discussed below.

## Working out the redundancy level

No decoded record carries single versus dual disk redundancy, and nothing Drobo
shipped reads one: Dashboard's own checkbox is populated through `DDService`'s
device model, and `ESAStatusEx::ComputeStatusEx` detects DDR/SDR *transitions*
by comparing its own stored state rather than reading a field.

It can be worked out from the capacities. BeyondRAID holds back the largest disk
for single redundancy and the two largest for dual, so:

| | |
|---|---|
| Raw installed, 2/2/4/2/4 TB | 14 002 770 862 080 |
| Usable | 5 962 106 142 720 |
| Held back | 8 040 664 719 360 |
| Largest disk | 4 000 787 030 016 |
| Two largest | 8 001 574 060 032 |

Held back / largest = **2.0098**. Held back / two largest = **1.0049**.

The owner of this 5D confirms it runs **dual** disk redundancy, which the second
ratio matches to half a percent. The two hypotheses are a factor of two apart,
so a tight window round 1.0 picks the level out with no room to confuse them,
and anything that fits neither is reported as undetermined rather than guessed.

This is worth writing down carefully because the first pass got it backwards.
`docs/TEARDOWN.md` asserted single redundancy — an unverified inference — and
that assertion was then used to "disprove" a derivation that was in fact
correct. The ground truth came from the person who owns the array. Where a
document and a measurement disagree, check which one was ever actually
observed.

`ESADiskPackInfo` (`0x11`) is still the most likely home for the setting as a
*reported* field rather than a derived one. Its `parse()` is a loop over a
per-slot structure and carries a `Flags` value; ReDrobo now reads the record and
keeps the raw bytes in its diagnostics report, so the next capture from a box
with a known setting can settle it.

## The firmware feature table

Separate from `Options2`'s `featureOnOffStates`. This one says what the
enclosure *supports*, and every bit is named by a call site of
`DroboDevice::IsFirmwareFeatureSupported` in Dashboard:

| Mask | Feature |
|---|---|
| `0x00000002` | Extended slot info, sub-page `0x35` |
| `0x00000004` | Background file check |
| `0x00000008` | Hot data cache — the mSATA accelerator |
| `0x00000010` | Activation mode |
| `0x00000020` | Drobo Apps |
| `0x00000080` | Volume resize |
| `0x00000200` | Backup volume |
| `0x00000800` | User event logs |
| `0x00001000` | Virtual machines |
| `0x00010000` | Light dimming |
| `0x00800000` | Extended LUN info |
| `0x08000000` | SCSI-4 reservations |
| `0x10000000` | Locator light |
| `0x20000000` | Transactional tier — enterprise auto-tiering, **not** the accelerator |

Bit 3 and bit 29 are different features and were briefly conflated here. Drobo
keeps them apart in its own resources — `kUIString_HotDataCache` and
`kUIString_AcceleratorActive` against `kUIString_TransactionalTier_*` and
`kUIString_AutoTiering` — and behind two separate accessors reading two separate
fields, `IsSSDCacheOn` and `IsTransactionalTierOn`. A 5D's accelerator is bit 3.

### Where the table is read from: `ESASystemInfo`, sub-page `0x33`

**Answered, 2026-08-19.** `ESAFirmwareInfo::getFeatureTable` returns an object
field that `parse()` never writes, so the table had to arrive from somewhere
else. `ESASystemInfo` (`0x33`) holds three big-endian u32 at `+0x08`, `+0x0C`
and `+0x10`, and a live 5D returns:

| Word | Value |
|---:|---|
| 0 | `0x0000B29E` |
| 1 | `0x00000027` |
| 2 | `0x00000000` |

Word 0 agrees with every check that can be made against the hardware in front
of it:

| Bit | Feature | In word 0 | Expected | Why |
|---:|---|---|---|---|
| 1 | Extended slot info | set | set | sub-page `0x35` does answer on this unit |
| 3 | Hot data cache | set | set | an mSATA accelerator is fitted |
| 5 | Drobo Apps | clear | clear | a NAS feature; this is direct attached |
| 29 | Transactional tier | clear | clear | an enterprise feature, and separate from the cache |

Word 0 also sets bits 13 and 15, which no recovered accessor names — expected,
since only bits with a named call site in Dashboard could be recovered at all.

Word 1 fails: it claims Drobo Apps and denies the hot data cache. It may be the
extended table `getExtFeatureTable` reads, which lives at a different object
offset, but nothing checks that. Word 2 is zero.

**This is one enclosure and four criteria, so it is a well-supported hypothesis
rather than a proof.** Another model, particularly one without an accelerator,
would settle it: word 0's bit 3 should follow the hardware.

### featureOnOffStates, and why it is a dead end

`featureOnOffStates` from `Options2` is a different field with different
numbering, observed as `0x3` on a live 5D. Exactly one of its bits is decoded
by anything Drobo shipped:

| Bit | Mask | Meaning |
|---:|---|---|
| 3 | `0x08` | Direct-attach iSCSI configured |

That comes from `ESABlockDevice::doPollESAUpdate`, which tests bit 3 and only
then reads the direct-attach iSCSI address and subnet mask out of the same
record. Every other consumer takes the value whole: `ESADevice::getProConfig`
copies the raw 64 bits into a `ProConfigInfo`, `constructHSESAUpdate` stores it
untouched, and the wide string `mFirmwareFeatureStates` sits in the Dashboard
binary referenced by nothing at all.

**And the obvious experiment does not work.** The only code that *writes* this
field is `ESADevice::setProConfig`, which is reached from exactly one place,
`DroboFSAdapter::setProConfig` — the Drobo FS and Pro iSCSI path. On a directly
attached enclosure Dashboard never writes `featureOnOffStates`, so changing
settings and re-reading the record cannot identify a bit: nothing Dashboard does
will move it.

So the remaining bits are not recoverable by reading Drobo's code, and not
recoverable by driving Drobo's app either. They would have to come from
comparing the field across enclosures in known-different configurations, and
nothing in ReDrobo depends on them. They are displayed and left unnamed.

### Records a 5D on 4.2.3 does not give you

- **`0x11` DiskPackInfo** answers, declares 343 bytes, and every one of them is
  zero. So the redundancy level is not in there, at least not on this firmware.
- **`0x80` DeviceSerial** is refused outright.

Both were asked for on the assumption they might carry something; neither does.
A client should ask once and remember the answer.

### The stale tail is worse than untidy

Bytes past a record's declared length are whatever was left in the enclosure's
buffer, and on a live 5D that is its **own event log, in plain text**:

```
222:CAPACITY="3.63TiB",SERIAL_NUMBER="WD-XXXXXXXXXXXXX",SLOT_NUMBER="2"
521:FS_TYPE="HFS+",LUN_NUMBER="0"
125:FREE_PERC="22.67",FREE_SPACE="1.22TiB"
```

(the serial is masked here; the real one is not). Disk serial numbers,
capacities, slot numbers, filesystem type, dated entries going back months. The enclosure name turns up the same way inside the tail of
`0x08`.

This matters for anything that dumps records for a bug report. Blanking the
fields you decode is not enough — the values reappear in records you do not
parse at all. ReDrobo learned this the hard way: its first "redacted" report
printed the enclosure name and five disk serials. It now searches the bytes for
every known value, and drops everything past a record's declared length —
falling back to a hard cap for `0x30` and `0x31`, whose declared lengths are
useless.

### Known wrinkles

The page length field is wrong for `0x30` and `0x31`. They report 2304 and
64513 for a struct that is only 1308 bytes. The payloads decode correctly at
the offsets above, so treat the length as unusable for those two rather than
trusting it.

Bytes past `4 + length` are stale buffer contents, not part of the record. The
`0x03` capture contained fragments of Drobo's own event log from November 2024,
including strings like `FREE_SPACE="1.29TiB"` and `SLOT_NUMBER="5"`. Interesting,
but do not parse it: it is whatever happened to be in the buffer.

### Cross-check against Dashboard

Every decoded value agreed with what Dashboard showed at capture time. Free plus
used equals total exactly. Dashboard labels its capacity figures TB but they are
TiB, and its "4.25 TB used" is the same 4.24 TiB the device reports, rounded.

One honest gap: the array reports 4 667 223 805 952 bytes used, while the HFS+
volume on top reports 4 673 582 972 928. The 5.9 GiB difference is filesystem
overhead against block level allocation, so the two will never match to the byte.
The earlier hope of using the HFS+ figure as an exact anchor was wrong; the
agreement is close, not exact.

## The other user-client entry points

Beyond mode pages the user client exposes:

- `vendorSpecificIn` / `vendorSpecificOut` — takes an `ESAVendorSpecificStruct`
  with `inPageNum` and `inSubPageCode`, returns an `ESAVendorResponseStruct`
  and captures 18 bytes of auto-sense data on failure.
- `vendorSpecificPassThroughIn` / `Out` — takes an `ESAVendorSpecificCDBStruct`,
  i.e. a caller-supplied raw CDB. This is the generic escape hatch.
- `ataReadCommandMethod` / `ataWriteCommandMethod` — a tunnel to individual
  drives in the pack. See below; this turned out not to be what it looked like.

For a status/monitoring reimplementation, only the mode-page path matters.

## The ATA tunnel, and why SMART is not built

The earlier guess was that per-drive ATA access needed vendor-specific opcodes,
and therefore `UserSuspendServices()` and an unmounted volume. That is wrong,
and the truth is more awkward.

`ataReadData` builds this:

```asm
movw  $0x28, (%r8)          ; cdb[0] = 0x28  READ(10), cdb[1] = 0
                            ; cdb[2..5] = LBA, big endian
                            ; cdb[7..8] = transfer length in blocks
movl  $0x2,  %ecx           ; direction = from target to initiator
movl  $0xa,  %r9d           ; CDB length = 10
callq CREATE_PASS_THROUGH_CDB
```

So it is an ordinary `READ(10)` at a magic LBA. `CREATE_PASS_THROUGH_CDB`
enforces an allowlist, recovered from its two bit-test masks
(`0x4000010000000001` and `0x1080000000001`):

| Opcode | Command |
|---|---|
| `0x12` | INQUIRY |
| `0x28` | READ(10) |
| `0x2A` | WRITE(10) |
| `0x52` | READ DEFECT DATA |
| `0x5A` | MODE SENSE(10) |
| `0xEA` | vendor |

No vendor opcode range, no exclusive access, no unmount. The mechanism is a
command mailbox at reserved LBAs: you write a request block with `WRITE(10)` and
read the answer back with `READ(10)`.

**Which is exactly why ReDrobo does not implement SMART.** Two reasons, and the
second is the real one:

1. Nothing shipped by Drobo uses this path. `DDService64d` and Dashboard have
   no SMART symbols and no callers — the entry points exist in the kext and were
   never wired up to anything a user could see. So there is no reference
   implementation to copy the LBA encoding from.
2. Finding that encoding means writing to reserved LBAs on a live array to see
   what answers. `WRITE(10)` at a guessed offset on a storage controller is the
   one operation in this whole project that could plausibly destroy a disk pack.

What ReDrobo shows instead is the per-disk health the enclosure already
publishes over the safe read-only path: state, error count, temperature, life
remaining, model, firmware revision and serial, all from sub-page `0x35`. That
is the same data Dashboard displayed, and Dashboard never showed raw SMART
either.

## The 26 personalities

The kext matched on these Vendor and Product Identification pairs. Read straight
out of `TrustedDataSCSIDriver.kext/Contents/Info.plist`, in its own
`Driver1`…`Driver26` order:

| # | Vendor | Product |
|---:|---|---|
| 1 | `TRUSTED` | `USB Mass Storage` |
| 2 | `TRUSTED` | `Mass Storage` |
| 3 | `DROBO` | `Drobo` |
| 4 | `DROBO` | `DroboPro` |
| 5 | `Drobo` | `DroboElite` |
| 6 | `Drobo` | `3rd Gen DRDR3-A` |
| 7 | `DROBO` | `Drobo3` |
| 8 | `Drobo` | `Drobo3` |
| 9 | `USB 3.0` | `Drobo S - Gen 2` |
| 10 | `Drobo` | `B800i` |
| 11 | `Drobo` | `Drobo` |
| 12 | `Drobo` | `B1200i` |
| 13 | `Drobo` | `5D - TB` |
| 14 | `Drobo` | `5D` |
| 15 | `Drobo` | `Mini - TB` |
| 16 | `Drobo` | `Mini` |
| 17 | `DROBO` | `5D` |
| 18 | `DROBO` | `Mini` |
| 19 | `Drobo` | *(none)* |
| 20 | `Drobo` | `Gen3` |
| 21 | `Drobo` | `B810i` |
| 22 | `Drobo` | `5C` |
| 23 | `Drobo` | `8D` |
| 24 | `Drobo` | `8D - TB` |
| 25 | `Drobo` | `5D3` |
| 26 | `Drobo` | `5D3 - TB` |

Three things worth noticing.

**Number 19 has no Product Identification at all.** Drobo shipped a Vendor-only
catch-all, which confirms the SCSI family matches on whichever keys a
personality carries. One entry for anything calling itself `Drobo`.

**Two vendors say nothing about Drobo.** A Drobo S Gen 2 answers INQUIRY as
`USB 3.0`, and the oldest units as `TRUSTED`. Anything scanning for Drobo
hardware by looking for the word will miss them, and anything matching those
two vendors alone would claim other manufacturers' devices.

**Number 14 is the one confirmed on hardware**, `Drobo` / `5D`, which is what
the live 5D in this repo answers.

## Device side

The Drobo 5D firmware (`release.Drobo5D.4-2-3.tdf`) is a VxWorks image:

```
offset 0x000  TDIH  header, 556 bytes
offset 0x16C  VXIM  VxWorks image marker
offset 0x22C  ELF32 little-endian, machine 40 (ARM)  -- main image
offset 0x3034A4 ELF32 ARM                            -- second image
```

Build paths inside it (`../../VxWorks/bsps/OptimusPrime_BSP_SMP_Gerty`,
`../../Alcatraz/platform/vxworks/sata`, `TDFeatureLib/osInterface/VxWorks`)
match the `Alcatraz` codename that also appears in the macOS driver's build
path, so host and device came out of one tree.

The firmware contains `processSCSIModePage`, `scanAllModePage`, `pageCode` and
`subPageCode` symbols, which is consistent with the host-side finding: the
enclosure answers management traffic from inside its normal SCSI target code
path, not over a side channel.

**Practical consequence:** the firmware needs no modification. It already
speaks a protocol any modern SCSI initiator can drive. This is a host-software
problem only.

## Still open

Each of these is one capture away from being settled, and each needs a Mac that
can still read the enclosure.

**Confirm the feature table on a second enclosure.** Word 0 of `0x33` fits every
check a single 5D can offer, but one unit cannot distinguish "this is the table"
from "this word happens to agree". A model without an accelerator is the useful
test: bit 3 should follow the hardware.

**What do the remaining `featureOnOffStates` bits mean?** Bit 3 is named; bits 0
and 1, the two a live 5D sets, are not. Neither reading Drobo's code nor driving
Drobo's app can settle them — see above. Closed as far as this project is
concerned.

**What do status bits 15 and 17 mean?** They are the two a healthy array sets
and they appear in no alert path. Confirmed still set, and still unexplained, on
the 2026-08-19 capture.

**Which redundancy level is set, as a reported field.** `0x11` was the candidate
and it came back empty, so the capacity derivation remains the only source. If
another model populates that record, it is worth another look.

**The hardware sensor records.** `ESAFanInfo` (`0x37`), `ESAPowerSupply`
(`0x36`), `ESABatteryInfo` (`0x3A`), `ESAControllerCard` (`0x38`) and
`ESAExpanderInfo` (`0x39`) all have a sub-page and a size, but their `print()`
methods carry no format strings, so the field names are not recoverable the easy
way and each layout would have to come out of `parse()` by hand.

## Validation status

| Claim | Evidence | Confidence |
|---|---|---|
| Opcodes `0x5A` / `0x55` | Immediates at the `CREATE_CDB` call sites | Certain |
| Page code `0x3A`, sub-page selects the record | Live capture: every reply came back `7A <subpage>` | **Confirmed** |
| Sub-page to record mapping | Live capture, values match Dashboard | **Confirmed** |
| Payload field offsets | Kext's own field reads, cross checked against Dashboard | **Confirmed** |
| Payload is big endian | Values only make sense that way, and they match Dashboard | **Confirmed** |
| Length field on `0x30` / `0x31` | Reports impossible values | Known broken |
| SlotInfo per drive status, serial, firmware rev | Visible in the bytes, not yet mapped | Open |
| StatusInfo bit meanings | Only the healthy value `0x00028000` observed | Open |
| `featureOnOffStates` bit meanings | Only `0x3` observed | Open |
| Reading records while the volume is mounted | Live run on macOS 27, volume stayed mounted | **Confirmed** |
| The 26 Vendor/Product pairs | Read from the kext's own `Info.plist` | Certain |
| Full record map, sub-page per class | `ESAProtocol::*::getSubPageType()` | Certain |
| SlotInfo2 (`0x35`) layout | `ESASlotInfoStruct2::parse`, then decoded field by field against a live 5D | **Confirmed** |
| SlotInfo2 entry stride of 108 | `calculateSize()`, and page byte 9 on the live capture | **Confirmed** |
| Disk state 0–3 | `DDUtils::GetDiskState` jump table; `0x10` and `0x11` seen live | **Confirmed** |
| Disk type 0 = hard disk, 4 = SSD | Live capture, five hard disks and one SSD | **Confirmed** |
| Rotational speed identifies an SSD | Live capture says no: a hard disk reads 0 | **Disproved** |
| Temperature on firmware 4.2.3 | Zero on every slot | Not populated |
| Status severity masks | Literal immediates in `getSeverityForStatus`; agree with the live healthy value | Certain |
| Status bit names | `AlertMailer::GetEventIDForStatus`, corroborated by the masks | High |
| Status bits 15 and 17 | Set on a healthy array, in no alert path | **Unknown, and left unnamed** |
| Capacity fields 4–7 | `ESACapacityInfoPT::parse`; live page length is 0x38 | **Confirmed** |
| Red alert threshold at `+0x05` | `ESAOptions::parse`; live value 95 | **Confirmed** |
| Spin down delay at `+0x0C` | Live value 14 minutes | **Confirmed** |
| `0x11` carries the redundancy level | Answers, but all zeros on 4.2.3 | **Disproved** |
| `0x80` DeviceSerial | Refused by 4.2.3 | Not available |
| Stale tails contain the event log | Serials and capacities in plain text, live | **Confirmed** |
| Firmware feature table bits | Every call site of `IsFirmwareFeatureSupported` | High |
| Where the feature table is read from | `parse()` never writes it | Open |
| `featureOnOffStates` bit 3 | `doPollESAUpdate` gates the iSCSI address on it | High |
| The other `featureOnOffStates` bits | Nothing reads them, and only the FS/Pro path writes them | **Not recoverable this way** |
| The firmware feature table lives in `0x33` word 0 | Live capture agrees with all four checks | **Well supported**, one enclosure |
| Bit 3 is the hot data cache, bit 29 is tiering | Separate strings, separate accessors, separate fields in Dashboard | High |
| Redundancy level, single vs dual | Not in any decoded record; not derivable from capacities | Open |
| ATA tunnel is `READ(10)`/`WRITE(10)` at a magic LBA | `ataReadData` plus the `CREATE_PASS_THROUGH_CDB` allowlist | High |
| The LBA encoding for that tunnel | No shipping caller anywhere | Open, and not worth the risk |
