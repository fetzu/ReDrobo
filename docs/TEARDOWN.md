# Phase 1 findings, first live run

Date: 2026-08-19. Drobo 5D "RAIDDEADREDEMPTION", firmware 4.2.3 [7.199.116068],
attached over USB 3 to a an Apple Silicon MacBook Pro running macOS 26.6.2.

Nothing was written to the device. The volume was never unmounted. Every result
below comes from reading the IORegistry plus one attempt to create a user client,
which failed before any SCSI command was sent.

## Headline: the SCSITaskUserClient path does not work

This is the important one, and it contradicts what the first analysis assumed.

```
$ ./droboprobe --check
  IOCreatePlugInInterfaceForService failed (0xe00002c7)
```

`0xe00002c7` is `kIOReturnUnsupported`: the nub publishes no `IOCFPlugInTypes`
entry for the SCSITask user client, so there is nothing to open.

Searching the whole IORegistry for the property that would have to be there
returns nothing at all:

| Query | Result |
|---|---|
| services publishing `SCSITaskDeviceCategory` | 0 |
| nubs carrying `IOMatchCategory = SCSITaskUserClientIniter` | 4 |
| `SCSITaskUserClientIniter` instances actually started | 0 |

So the match category is reserved on every SCSI nub, but the initer never
starts, and its `IOProviderMergeProperties` never merge. Apple's own header says
why, and it was there to read the whole time:

> SCSITaskLib implements non-kernel task access to specific IOKit object types,
> namely any SCSI Peripheral Device **for which there isn't an in-kernel driver**
> and for authoring devices such as CD-R/W and DVD-R/W drives.

The Drobo is claimed by Apple's own `IOSCSIPeripheralDeviceType00`, so it has an
in-kernel driver and gets no user client. The generic path is for peripherals
nothing else wants, and for optical burners.

### What that means for the earlier conclusion

The first write-up called Drobo's kext "a convenience wrapper that was never
doing anything the kernel had to do". That was wrong, and worth stating plainly.
Because macOS will not hand out a SCSI passthrough user client for a claimed
block device, replacing the in-kernel Type00 driver was the only way to get a
management channel at all. Drobo's design was forced, not lazy.

The protocol finding itself is unaffected: the CDB shape and the mode page map
came from disassembling the kext, not from this path.

## No alternative back door

Checked and ruled out, all read-only:

The enclosure exposes exactly one USB interface, `IOUSBHostInterface@0`, and it
is claimed by the mass storage stack. There is no second vendor-specific
interface to claim from userspace with IOUSBHost.

It also exposes exactly one logical unit, LUN 0. There is no unclaimed second
LUN that the SCSITask initer might have attached to.

The full stack as it stands today:

```
Drobo5D@00230000                     IOUSBHostDevice
 └ IOUSBHostInterface@0
    └ IOUSBMassStorageInterfaceNub
       └ IOUSBMassStorageDriverNub
          └ IOUSBMassStorageDriver
             └ IOSCSILogicalUnitNub@0          Vendor "Drobo", Product "5D", Rev "5.00"
                └ IOSCSIPeripheralDeviceType00  Apple's, and it owns the LUN
                   └ IOBlockStorageServices
                      └ IOBlockStorageDriver
                         └ Drobo 5D Media       IOMedia
                            └ IOGUIDPartitionScheme
                               ├ EFI System Partition@1
                               └ DroboVolume@2  HFS+, mounted
```

Note the nub is an `IOSCSILogicalUnitNub`, a subclass of the
`IOSCSIPeripheralDeviceNub` the kext matched on. `IOProviderClass` matching
covers subclasses, so the old personalities would still match. It also carries
the INQUIRY strings flat rather than in a `Device Characteristics` dict, which
`droboprobe` now handles.

## The good news from the same run

Storage works perfectly with no third-party code anywhere. The volume mounted on
its own, and the INQUIRY identity is exactly the one the kext's personality
number 14 was written for, `Vendor "Drobo"` and `Product "5D"`.

## Why any of this matters, in one number

`diskutil` and Drobo Dashboard disagree about this array, and the gap is the
whole argument for the project.

| Source | Total | Used | Free |
|---|---|---|---|
| Dashboard on the iMac | 5.42 TB | 4.25 TB | 1.17 TB |
| macOS, this Mac, HFS+ volume | 17.6 TB | 4.7 TB (4673582972928 bytes) | 12.9 TB |

The Drobo advertises a thin-provisioned 16 TiB LUN and reports the real array
capacity only over the management channel. Without that channel the operating
system believes there are 12.9 TB free when there are actually 1.17 TB. That is
not a cosmetic loss. It is the difference between a warning and a full array.

Useful side effect: Dashboard's "4.25 TB" used is 4.25 TiB, which is
4673582972928 bytes, and that is byte-for-byte the HFS+ used space macOS
reports. So the Dashboard numbers are TiB mislabelled as TB, and we have an
exact 64-bit anchor value to search for once we can read the CapacityInfo
record.

## Dashboard reference values, captured before moving the enclosure

From the iMac, firmware 4.2.3, interface USB, taken 2026-08-19. These are the
values to match the record bytes against.

| Field | Value |
|---|---|
| Name | RAIDDEADREDEMPTION |
| Serial number | DRBxxxxxxxxxxx |
| Health | Good |
| Firmware | 4.2.3 [7.199.116068] |
| Uptime at capture | 0 days 00:38 |
| Hot Data Cache | On, mSATA accelerator active |
| Active interface | USB |
| Bays, top to bottom | 2 TB, 2 TB, 4 TB, 2 TB, 4 TB, all green |
| Total | 5.42 TB (TiB) |
| Used | 4.25 TB (TiB) = 4673582972928 bytes |
| Free | 1.17 TB (TiB) |

Raw disk total is 14 TB across five bays, presented as 5.42 TiB usable.

**Correction, 2026-08-19.** This originally read "consistent with single-disk
redundancy", which was a guess and was wrong. The owner confirms the array runs
**dual disk redundancy**, and the arithmetic agrees once you check it: 14.00 TB
of disks presenting 5.96 TB holds back 8.04 TB, against two largest disks of
8.00 TB. That is a 0.5% fit for dual and nowhere near the 4.00 TB single would
predict. See [PROTOCOL.md](PROTOCOL.md#working-out-the-redundancy-level).

## Where this leaves the plan

Path A is gone. The DriverKit dext is now the only sanctioned way to reach the
device, which promotes the family entitlement from an open question to the
critical path.

Decoding the record payloads no longer depends on the dext, though. The kext is
still installed and working on an older Mac that still runs Dashboard, and its user client is a normal
`IOUserClient`. A small tool that opens
`com_TrustedData_UserClient_SCSIType00` and calls only the read selector would
capture the authoritative payload bytes, with Dashboard right there for
cross-checking, and without changing the security settings of either machine.
That is the cheapest route to the protocol spec, which is the artifact that
outlives all of this.
