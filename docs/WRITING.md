# Writing to a Drobo

Nothing in ReDrobo writes to an enclosure. This document exists so that whoever
decides to change that starts from what is known rather than from scratch, and
so the risks are written down before anyone is tempted.

Everything here was recovered from `TrustedDataSCSIDriver.kext` and
`DDService64d` (Drobo Dashboard 3.6.1, build 115880). None of it has been sent
to a real enclosure by this project. Read [Before you write
anything](#before-you-write-anything) first.

## There are two mechanisms, not one

This is the thing to understand before anything else, because they have
completely different consequences under DriverKit.

| | Settings | Actions |
|---|---|---|
| Command | `MODE SELECT(10)`, opcode `0x55` | vendor opcode `0xEA` |
| Changes | thresholds, name, clock, feature states | standby, identify, restart, power off, format |
| Standard SCSI? | Yes | **No**, `0xEA` is in the vendor range |
| Needs exclusive access? | No | **Yes** |
| Volume can stay mounted? | Yes | **No** |

`MODE SELECT(10)` is an ordinary SPC command, so `UserSendCDB` will carry it
with the volume mounted, exactly as `MODE SENSE(10)` already is.

`0xEA` is not. Apple's rule is that DriverKit refuses vendor-specific opcodes in
`0xC0`–`0xFF` unless the driver has called `UserSuspendServices()`, and that
requires the volume to be unmounted first. So every action in the second column
is an explicit, disruptive, user-initiated operation and can never be something
the app does quietly.

## Settings: MODE SELECT(10)

The CDB is the one already documented in [PROTOCOL.md](PROTOCOL.md), with the
opcode changed. `CREATE_CDB` in the kext is shared between both directions and
`SetModePage` differs from `GetModePage` only by `movl $0x55, %ecx`:

```
55 00 3A pp 00 00 00 LL LL 00
      └┴─ vendor page 0x3A, sub-page pp selects the record
```

The kext's own error strings confirm the path: `MODE_SELECT_10_EXTENDED`,
`SetModePage(%u, ...)`, and the user client entry point `sSetESAModePage`.

### The payload

Every `ESAProtocol` class has a `generate()` alongside its `parse()`, and
`generate()` is the encoder. It writes the same layout `parse()` reads, so the
field maps in [PROTOCOL.md](PROTOCOL.md) are the write format as well as the
read format. The shape is always:

```
byte 0    0x7A
byte 1    sub-page
byte 2-3  page length, big endian, from calculateModePageSize()
byte 4+   payload
```

`ESASystemSettings::generate` opens with `movw $0x57A, (%r14)` and
`ESAOptions::generate` with `movw $0x307A, (%r12)` — little-endian 16-bit stores
of `7A 05` and `7A 30` respectively. Both `bzero` the buffer first, so unset
fields go out as zero rather than as whatever was there.

**The endianness of individual fields in `generate()` has not been verified
field by field.** The read paths clearly byte-swap (`ntohll`, `bswapl`, `rolw`);
the corresponding stores in `generate()` need checking one at a time before any
of them is trusted. Getting this wrong means writing a plausible-looking but
wrong value into a storage controller's settings.

### Which records are writable

| Sub-page | Record | What it would change |
|---:|---|---|
| `0x05` | `ESASystemSettings` | enclosure name, clock, GMT offset |
| `0x30` | `ESAOptions` | yellow and red thresholds, data check settings |
| `0x31` | `ESAOptions2` | feature on/off states, spin down delay |
| `0x0A` | `ESASetCHAP` | iSCSI CHAP credentials |
| `0x0B` | `ESASetSingleInitiator` | iSCSI single-initiator enforcement |
| `0x0C` | `ESASetUsedCapacity` | tells the array how much a LUN is using |
| `0x0D` | `ESASetLUNName` | volume name |

`0x0A` through `0x0D` exist only to be written; there is nothing to read back.

`ESASCSISession` wraps them as `setOptions`, `setOptions2` and
`setSystemSettings`, all of which tail-call one function,
`setESAModePageObject(ESAModePageData&)`. So the write path is uniform: fill in
the object, call `generate()`, send `MODE SELECT(10)`.

## Actions: vendor opcode 0xEA

`ESASystemOperationRequest`'s constructor builds a fixed 10-byte CDB:

```
byte 0   0xEA        vendor opcode
byte 1   0x10
byte 2   (argument)
byte 3   operation ID
byte 4   (argument)
byte 5   0x00
byte 6   (argument)
byte 7-8 transfer length, big endian
byte 9   (argument)
```

`ESASCSISession::sendSystemOperation(unsigned char)` sends one with a one-byte
buffer; overloads exist that carry a payload and a direction. The LUN goes in
shifted left by six, which is the classic pre-SAM CDB LUN field.

### The operation IDs

Recovered from every call site of `sendSystemOperation`, plus the trace string
`ESA_SYSOPID_STANDBY_ESA` which names `0x0D`:

| ID | Operation | Notes |
|---:|---|---|
| `0x02` | Format the array | destroys everything |
| `0x03` | Restart the enclosure | |
| `0x06` | Identify | blinks the lights; the only harmless one |
| `0x08` | Set the capacity LEDs | |
| `0x09` | Set demo mode | |
| `0x0B` | Set used capacity | |
| `0x0D` | Standby | `ESA_SYSOPID_STANDBY_ESA` |
| `0x0F` | Resize LUNs | |
| `0x15` | Read host buffer | |
| `0x16` | Write host buffer | |
| `0x17` | Power off | |
| `0x18` | Set dim level | LED brightness |
| `0x20` | Get next unique LUN ID | reads |
| `0x21` | Get dim level | reads |
| `0x81` | Get extended LUN info | reads |
| `0x83` | Get extended LUN info 2 | reads |
| `0x84` | Get LUN initiator info | reads |

Note the reads in that table. Several things Dashboard displayed came through
`0xEA` rather than a mode page, which means a DriverKit reimplementation cannot
have them without unmounting either. That is a good argument for leaving them
out: none is worth an unmount.

## What is still unknown

- **Field-by-field endianness in `generate()`.** See above. This is the single
  thing that must be settled before the first write.
- **What each `featureOnOffStates` bit does.** Writing `Options2` without
  knowing means changing settings blind. See [PROTOCOL.md](PROTOCOL.md).
- **The arguments to most `0xEA` operations.** Only the operation ID is mapped;
  bytes 2, 4, 6 and 9 carry something for at least some of them.
- **Whether the enclosure validates.** No idea whether firmware rejects a
  malformed page cleanly or acts on it.

## Before you write anything

**Use an enclosure with nothing on it.** Not a backup of the array — a pack you
would be content to lose, in a box you would be content to brick. This is the
only advice in this document that is not negotiable.

A rough order of increasing risk, if someone is going to do this anyway:

1. **Identify (`0xEA`, `0x06`).** Blinks the lights. Changes no state at all, so
   it is the right first thing to prove the `0xEA` path works — although it
   still costs an unmount, which makes it a poor fit for the app.
2. **Yellow and red thresholds (`0x30`).** Two bytes, obviously bounded, and
   wrong values only make the app's own warnings wrong.
3. **Enclosure name (`0x05`).** Cosmetic, but it shares a record with the clock,
   so a bad write moves the clock too.
4. **Spin down delay (`0x31`).** Now you are writing a 64-bit feature field you
   do not fully understand, next to a value you do.
5. **Nothing else.**

Specifically not worth building, ever, on an array anyone cares about:

- **Format (`0xEA`, `0x02`)**, which is the whole point of the enclosure gone.
- **Firmware update.** The `.tdf` container is understood — 556 byte header,
  `VXIM` marker, ARM ELF images — but the transfer mechanism is not, and a
  failed firmware write bricks the enclosure and takes the disk pack with it.
  The last firmware is already the final one and is already installed. There is
  no version of this that pays for itself.
- **The ATA mailbox.** Covered in [PROTOCOL.md](PROTOCOL.md): reserved LBAs
  driven by `READ(10)` and `WRITE(10)`, with no shipping caller anywhere to copy
  the encoding from. Finding it means `WRITE(10)` at guessed offsets on a live
  array.

## Why ReDrobo does not do any of this

The app reads. That is the whole design, and it is why the driver only ever
issues `MODE SENSE(10)` and why `MODE SELECT` is not reachable from the UI even
by accident.

The reasoning is not squeamishness. Reading is provably safe: a standard opcode,
no exclusive access, the volume stays mounted, and the worst outcome is a record
that fails to decode. Writing puts a malformed mode page into a storage
controller whose firmware source nobody has, on top of a proprietary RAID layout
nobody has reimplemented, where the failure mode is a disk pack that only
another Drobo can read — and there are no more Drobos being made.

The thing ReDrobo exists to fix is not being able to see the array. That is
fixed. The rest is optional, and the cost of getting it wrong has not gone down
just because the protocol is now understood.
