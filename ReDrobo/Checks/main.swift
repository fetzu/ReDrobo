//  Checks/main.swift
//
//  What can be verified without a Drobo attached.
//
//  These are not unit tests in the ceremonial sense. They are the specific
//  claims this project makes about a protocol nobody documented, checked
//  against the one live capture that exists (docs/PROTOCOL.md, a Drobo 5D on
//  firmware 4.2.3) and against layouts recovered from Drobo's own binaries.
//
//  They earn their place: the redundancy derivation was removed once on the
//  strength of a failing check here, and put back once the check was corrected
//  against ground truth. Run with `make check`.

import Foundation

// Rebuild the records docs/PROTOCOL.md says a live Drobo 5D returned, and check
// the decoder still produces the values that were cross-checked against
// Dashboard on 2026-08-19.

func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8((v >> ($0 * 8)) & 0xFF) } }

func page(_ sub: UInt8, _ payload: [UInt8]) -> Data {
    var d: [UInt8] = [0x7A, sub, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    d += payload
    d += [UInt8](repeating: 0, count: max(0, 1308 - d.count))
    return Data(d)
}

var fails = 0
func check(_ what: String, _ got: Any, _ want: Any) {
    let ok = "\(got)" == "\(want)"
    if !ok { fails += 1 }
    print("\(ok ? "ok  " : "FAIL") \(what): got \(got)\(ok ? "" : ", want \(want)")")
}

// --- 0x02 CapacityInfo -----------------------------------------------------
var cap: [UInt8] = be64(1_294_882_336_768) + be64(4_667_223_805_952) + be64(5_962_106_142_720)

// --- 0x03 SlotInfo, six 72 byte entries ------------------------------------
let slots: [(UInt64, String)] = [
    (2_000_398_934_016, "WDC WD20EZRX-00D"),
    (2_000_398_934_016, "WDC WD20EZRX-00D"),
    (4_000_787_030_016, "WDC WD40EFRX-68N"),
    (2_000_398_934_016, "WDC WD20EFRX-68E"),
    (4_000_787_030_016, "WDC WD40EFRX-68N"),
    (128_035_676_160,  "M4-CT128M4SSD3"),
]
var slotPayload: [UInt8] = [UInt8(slots.count)]
for (capacity, model) in slots {
    var entry = [UInt8](repeating: 0, count: 72)
    entry.replaceSubrange(3..<11, with: be64(capacity))
    let text = Array((model + String(repeating: " ", count: 20 - min(20, model.count)) + "SATA").utf8)
    entry.replaceSubrange(20..<(20 + text.count), with: text)
    slotPayload += entry
}

// --- 0x05 SystemSettings, 0x30 Options -------------------------------------
var sys = [UInt8](repeating: 0, count: 64)
sys.replaceSubrange(4..<6, with: [0, 120])                 // gmtOffset at 0x08
sys.replaceSubrange(6..<13, with: Array("MYDROBO".utf8))   // name at 0x0A, invented

let records: [UInt8: Data] = [
    0x02: page(0x02, cap),
    0x03: page(0x03, slotPayload),
    0x05: page(0x05, sys),
    0x30: page(0x30, [85]),
]

let s = DroboSnapshot.decode(records)

check("free",   s.freeBytes,  1_294_882_336_768)
check("used",   s.usedBytes,  4_667_223_805_952)
check("total",  s.totalBytes, 5_962_106_142_720)
check("free+used == total", s.freeBytes + s.usedBytes, s.totalBytes)
check("used percent", s.usedPercent, 78)
check("name", s.name, "MYDROBO")
check("gmt offset minutes", s.gmtOffsetMinutes, 120)
check("threshold", s.yellowThresholdPercent, 85)

check("slots decoded", s.bays.count, 6)
check("drive bays", s.driveBays.count, 5)
check("accelerator present", s.accelerator != nil, true)
check("accelerator is the last slot", s.accelerator?.id ?? -1, 5)
check("bay 1 model", s.driveBays[0].model, "WDC WD20EZRX-00D")
check("bay 1 capacity", s.driveBays[0].capacityBytes, 2_000_398_934_016)
check("bay 3 capacity", s.driveBays[2].capacityBytes, 4_000_787_030_016)
check("bay labels", s.driveBays.map(\.label).joined(separator: ","),
      "Bay 1,Bay 2,Bay 3,Bay 4,Bay 5")
check("accelerator label", s.accelerator?.label ?? "", "Accelerator")
check("used as TiB", Fmt.tib(s.usedBytes), "4.24 TB")
check("free as TiB", Fmt.tib(s.freeBytes), "1.18 TB")
check("total as TiB, as Dashboard showed", Fmt.tib(s.totalBytes), "5.42 TB")

// --- the accelerator rule on models that have no accelerator ---------------
check("five equal bays, no accelerator",
      DroboSnapshot.acceleratorSlot(in: [4_000_787_030_016, 4_000_787_030_016,
                                         4_000_787_030_016, 4_000_787_030_016,
                                         4_000_787_030_016]) as Any, "nil")
check("a small disk in a real bay is not an accelerator",
      DroboSnapshot.acceleratorSlot(in: [500_000_000_000, 4_000_787_030_016,
                                         320_000_000_000, 0]) as Any, "nil")
check("small last slot next to big ones is",
      DroboSnapshot.acceleratorSlot(in: [2_000_398_934_016, 2_000_398_934_016,
                                         128_035_676_160]) ?? -1, 2)
check("empty last slot is not",
      DroboSnapshot.acceleratorSlot(in: [2_000_398_934_016, 0]) as Any, "nil")

// --- volume matching -------------------------------------------------------
let vols = [
    VolumeInfo(name: "Macintosh HD", mountPoint: "/", device: "/dev/disk3s1",
               totalBytes: 500, freeBytes: 100),
    VolumeInfo(name: "DroboVolume", mountPoint: "/Volumes/DroboVolume",
               device: "/dev/disk4s2", totalBytes: 17_600_000_000_000,
               freeBytes: 12_900_000_000_000),
    VolumeInfo(name: "Other", mountPoint: "/Volumes/Other", device: "/dev/disk40s1",
               totalBytes: 1, freeBytes: 1),
]
check("volume for disk4",  Volumes.on(disk: "disk4",  from: vols)?.name ?? "nil", "DroboVolume")
check("volume for disk40", Volumes.on(disk: "disk40", from: vols)?.name ?? "nil", "Other")
check("volume for disk9",  Volumes.on(disk: "disk9",  from: vols)?.name ?? "nil", "nil")
check("no disk name",      Volumes.on(disk: nil,      from: vols)?.name ?? "nil", "nil")


// ---------------------------------------------------------------------------
// Extended slot record, sub-page 0x35. Layout recovered from
// ESAProtocol::ESASlotInfoStruct2::parse in DDService64d.
// ---------------------------------------------------------------------------

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
func be32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8((v >> ($0 * 8)) & 0xFF) } }
func str(_ s: String, _ n: Int) -> [UInt8] {
    var b = Array(s.utf8).prefix(n - 1).map { $0 }
    b += [UInt8](repeating: 0, count: n - b.count)
    return b
}

struct Slot2 {
    var id: UInt8, status: UInt8, errors: UInt16, state: UInt32
    var type: UInt8, temp: UInt8, life: UInt8, rpm: UInt8
    var make: String, fw: String, serial: String
    var total: UInt64, managed: UInt64
}

func slot2Entry(_ s: Slot2) -> [UInt8] {
    var e: [UInt8] = []
    e += [s.id, s.status]
    e += be16(s.errors)
    e += be32(s.state)
    e += [s.type, s.temp, s.life, s.rpm]
    e += str(s.make, 44)
    e += str(s.fw, 12)
    e += str(s.serial, 24)
    e += be64(s.total)
    e += be64(s.managed)
    precondition(e.count == 108, "slot entry must be 108 bytes, got \(e.count)")
    return e
}

let slot2s = [
    Slot2(id: 0, status: 1, errors: 0, state: 0, type: 0, temp: 34, life: 0, rpm: 5,
          make: "WDC WD20EZRX-00D8PB0", fw: "80.00A80", serial: "WD-EXAMPLESERIAL1",
          total: 2_000_398_934_016, managed: 2_000_398_934_016),
    Slot2(id: 1, status: 1, errors: 3, state: 2, type: 0, temp: 41, life: 0, rpm: 5,
          make: "WDC WD40EFRX-68N32N0", fw: "82.00A82", serial: "WD-EXAMPLESERIAL2",
          total: 4_000_787_030_016, managed: 4_000_787_030_016),
    Slot2(id: 2, status: 1, errors: 0, state: 3, type: 0, temp: 39, life: 0, rpm: 5,
          make: "WDC WD20EFRX-68EUZN0", fw: "82.00A82", serial: "WD-EXAMPLESERIAL3",
          total: 2_000_398_934_016, managed: 2_000_398_934_016),
    Slot2(id: 3, status: 1, errors: 0, state: 0, type: 4, temp: 30, life: 94, rpm: 0,
          make: "M4-CT128M4SSD3", fw: "070H", serial: "0000000012345678",
          total: 128_035_676_160, managed: 128_035_676_160),
]

var s2: [UInt8] = [UInt8](repeating: 0, count: 8)   // 4 header + 4 filler
s2 += [UInt8(slot2s.count)]                          // slot count at page +0x08
s2 += [0, 0, 0]                                      // to the 12 byte header
for e in slot2s { s2 += slot2Entry(e) }
// page() adds the 4 byte framing, so drop the placeholder header bytes.
let slots2Record = page(0x35, Array(s2.dropFirst(4)))

var recs2 = records
recs2[0x35] = slots2Record
recs2[0x02] = page(0x02, be64(1_294_882_336_768) + be64(4_667_223_805_952)
                        + be64(5_962_106_142_720) + be64(0))
let x = DroboSnapshot.decode(recs2)

print("\n--- extended slot record 0x35 ---")
check("extended detected", x.hasExtendedSlots, true)
check("slot count", x.bays.count, 4)
check("bay 1 model", x.bays[0].model, "WDC WD20EZRX-00D8PB0")
check("bay 1 firmware", x.bays[0].firmwareRevision, "80.00A80")
check("bay 1 serial", x.bays[0].serial, "WD-EXAMPLESERIAL1")
check("bay 1 capacity", x.bays[0].capacityBytes, 2_000_398_934_016)
check("bay 1 temperature", x.bays[0].temperatureC ?? -1, 34)
check("bay 1 health", x.bays[0].health.label, "Good")
check("bay 1 is a hard disk", x.bays[0].kind.label, "Hard disk")
check("bay 2 health is warning", x.bays[1].health.label, "Warning")
check("bay 2 error count", x.bays[1].errorCount, 3)
check("bay 3 health is failed", x.bays[2].health.label, "Failed")
check("bay 3 needs attention", x.bays[2].needsAttention, true)
check("good bay does not", x.bays[0].needsAttention, false)
check("SSD detected as accelerator", x.accelerator?.id ?? -1, 3)
check("accelerator life remaining", x.accelerator?.lifeRemainingPercent ?? -1, 94)
check("accelerator is an SSD", x.accelerator?.kind.label ?? "", "SSD")
check("drive bays exclude it", x.driveBays.count, 3)

print("\n--- status word ---")
check("healthy 5D is green", String(describing: DroboStatus.severity(of: 0x00028000)), "green")
check("bad disk is red", String(describing: DroboStatus.severity(of: 0x10)), "red")
check("yellow threshold is yellow", String(describing: DroboStatus.severity(of: 0x4)), "yellow")
check("relayout is yellow", String(describing: DroboStatus.severity(of: 0x200)), "yellow")
check("no redundancy is red", String(describing: DroboStatus.severity(of: 0x40)), "red")
check("fan failure is red", String(describing: DroboStatus.severity(of: 0x400000)), "red")
check("power supply is yellow", String(describing: DroboStatus.severity(of: 0x100000)), "yellow")
check("names bad disk", DroboStatus.named(0x10).first?.name ?? "", "Bad disk")
check("names relayout", DroboStatus.named(0x200).first?.name ?? "", "Relayout in progress")
check("healthy bits are unnamed", DroboStatus.named(0x00028000).count, 0)
check("healthy bits still listed", DroboStatus.decompose(0x00028000).count, 2)
check("protected when bit 6 clear", DroboSnapshot.decode(recs2).isProtected, true)

print("\n--- protection ---")
// 2 + 4 + 2 TB raw, 5.42 TiB usable: one 4 TB disk held back is single redundancy.
check("raw installed", x.rawInstalledBytes, 8_001_584_898_048)
check("reserved is positive", x.reservedForProtectionBytes > 0, true)

/// A pack of the given disk sizes presenting `usable` bytes.
func pack(_ disks: [UInt64], usable: UInt64) -> DroboSnapshot {
    var s = DroboSnapshot()
    s.bays = disks.enumerated().map { DriveBay(id: $0.offset, capacityBytes: $0.element) }
    s.totalBytes = usable
    return s
}

let TB2: UInt64 = 2_000_398_934_016
let TB4: UInt64 = 4_000_787_030_016

// The real 5D this app was built on: 2/2/4/2/4 TB presenting 5.42 TiB, and
// known from the owner to be running DUAL redundancy. Held back is 8.04 TB
// against two largest of 8.00 TB, a 0.5% fit.
let live = pack([TB2, TB2, TB4, TB2, TB4], usable: 5_962_106_142_720)
check("live 5D reads as dual", String(describing: live.redundancy), "dual")
check("and fits closely", live.redundancyFit.map { String(format: "%.3f", $0) } ?? "-", "1.005")

// Same pack with only the largest disk held back is the single-redundancy case.
let single = pack([TB2, TB2, TB4, TB2, TB4],
                  usable: 14_002_770_862_080 - TB4)
check("one disk held back reads as single", String(describing: single.redundancy), "single")

// Uniform packs must not be ambiguous either.
check("five equal disks, one held back",
      String(describing: pack([TB4, TB4, TB4, TB4, TB4], usable: TB4 * 4).redundancy), "single")
check("five equal disks, two held back",
      String(describing: pack([TB4, TB4, TB4, TB4, TB4], usable: TB4 * 3).redundancy), "dual")
check("nothing held back is no redundancy",
      String(describing: pack([TB4, TB4], usable: TB4 * 2).redundancy), "none")
check("a nonsense split is refused",
      String(describing: pack([TB4, TB4, TB4], usable: TB4 * 3 / 5).redundancy), "unknown")
check("no disks at all is unknown", String(describing: DroboSnapshot().redundancy), "unknown")
check("empty snapshot has no raw capacity", DroboSnapshot().rawInstalledBytes, 0)
check("usable share of an empty snapshot", DroboSnapshot().usableFraction, 0.0)

print("\n--- firmware feature table ---")
check("SSD cache bit", FirmwareFeature.present(in: 0x8).first?.label ?? "", "Hot data cache")
check("tiering bit", FirmwareFeature.present(in: 0x20000000).first?.label ?? "",
      "Transactional tier")
check("several at once", FirmwareFeature.present(in: 0x2000_0008).count, 2)

print("\n--- device identity ---")
check("Drobo vendor", DroboIdentity.isDrobo(vendor: "Drobo", product: "5D"), true)
check("DROBO vendor", DroboIdentity.isDrobo(vendor: "DROBO", product: "Mini"), true)
check("Drobo S Gen 2", DroboIdentity.isDrobo(vendor: "USB 3.0", product: "Drobo S - Gen 2"), true)
check("old TRUSTED unit", DroboIdentity.isDrobo(vendor: "TRUSTED", product: "Mass Storage"), true)
check("a random USB 3.0 disk is not", DroboIdentity.isDrobo(vendor: "USB 3.0", product: "Flash Disk"), false)
check("a random TRUSTED thing is not", DroboIdentity.isDrobo(vendor: "TRUSTED", product: "Widget"), false)
check("Seagate is not", DroboIdentity.isDrobo(vendor: "Seagate", product: "Backup+ Hub"), false)


// ---------------------------------------------------------------------------
// A real capture: sub-page 0x35 exactly as a live Drobo 5D on firmware 4.2.3
// answered it, 2026-08-19. The disk serial fields are zeroed, as the owner sent
// them. Model and firmware strings are hardware identity, not anyone's, and are
// what make this worth keeping.
//
// This fixture exists because four decode bugs shipped before anyone had seen
// these bytes: hard disks reported as SSDs and the SSD as a hard disk, the
// interface marker glued onto every model name, and SSD wear shown against
// spinning disks. All four are checked below.
// ---------------------------------------------------------------------------

let liveSlotInfo2Hex = """
7a35029094020100066c00000003000600000011000064002020202020202020
5744432057443230455a52582d30304453415441202020202020202020202020
0000000038302e30304138300000000000000000000000000000000000000000
0000000000000000000001d1c111600000000000000000000103000000000010
0000640020202020202020205744432057443230455a52582d30304453415441
2020202020202020202020200000000038302e30304138300000000000000000
0000000000000000000000000000000000000000000001d1c111600000000000
0000000002030000000000100000641b20202020202020205744432057443430
454652582d36384e534154412020202020202020202020200000000038322e30
3041383200000000000000000000000000000000000000000000000000000000
000003a3817d6000000000000000000003030000000000100000641b20202020
202020205744432057443230454652582d363845534154412020202020202020
202020200000000038322e303041383200000000000000000000000000000000
000000000000000000000000000001d1c1116000000000000000000004030000
000000100000641b20202020202020205744432057443430454652582d36384e
534154412020202020202020202020200000000038322e303041383200000000
000000000000000000000000000000000000000000000000000003a3817d6000
0000000000000000050300000000002004005b0120202020202020204d342d43
543132384d345353443320205341544120202020202020202020202000000000
30344d4820202020000000000000000000000000000000000000000000000000
000000000000001dcf8560000000000000000000
"""

func bytes(fromHex hex: String) -> Data {
    let digits = Array(hex.filter { $0.isHexDigit })
    var out = [UInt8]()
    out.reserveCapacity(digits.count / 2)
    for i in stride(from: 0, to: digits.count - 1, by: 2) {
        out.append(UInt8(String(digits[i...i+1]), radix: 16) ?? 0)
    }
    return Data(out)
}

let liveRecords: [UInt8: Data] = [
    0x35: bytes(fromHex: liveSlotInfo2Hex),
    0x02: bytes(fromHex: "7a0200380000012d7dfdb0000000043eab3a50000000056c293800000000000000000000000000000000000000000000000000000000000000000000"),
    0x09: bytes(fromHex: "7a0900100002800000000000"),
    0x30: bytes(fromHex: "7a300900555f0000"),
    0x31: bytes(fromHex: "7a31fc010000000000000003000e"),
    0x01: bytes(fromHex: "7a0100180609100000000800"),
]

let capture = DroboSnapshot.decode(liveRecords)

print("\n--- against the live 5D capture, firmware 4.2.3 ---")
check("six slots reported", capture.bays.count, 6)
check("five drive bays", capture.driveBays.count, 5)
check("accelerator found", capture.accelerator?.id ?? -1, 5)

check("bay 1 model has no interface marker", capture.bays[0].model, "WDC WD20EZRX-00D")
check("accelerator model likewise", capture.accelerator?.model ?? "", "M4-CT128M4SSD3")

// The bug that shipped: type 0 with rotational speed 0 is a hard disk, not an
// SSD, and the SSD is type 4 with rotational speed 1.
check("bay 1 is a hard disk", capture.bays[0].kind.label, "Hard disk")
check("bay 2 is a hard disk", capture.bays[1].kind.label, "Hard disk")
check("bay 3 is a hard disk", capture.bays[2].kind.label, "Hard disk")
check("the accelerator is the SSD", capture.accelerator?.kind.label ?? "", "SSD")

check("bay 1 healed with errors", capture.bays[0].health.label, "Healed")
check("bay 1 error count", capture.bays[0].errorCount, 6)
check("bay 2 good", capture.bays[1].health.label, "Good")

// Wear is an SSD metric; every hard disk here reports a placeholder 100.
check("no wear figure for a hard disk", capture.bays[0].lifeRemainingPercent == nil, true)
check("wear for the SSD", capture.accelerator?.lifeRemainingPercent ?? -1, 91)
check("this firmware reports no temperature",
      capture.bays.allSatisfy { $0.temperatureC == nil }, true)

check("bay 1 capacity", capture.bays[0].capacityBytes, 2_000_398_934_016)
check("bay 3 capacity", capture.bays[2].capacityBytes, 4_000_787_030_016)
check("accelerator capacity", capture.accelerator?.capacityBytes ?? 0, 128_035_676_160)
check("bay 1 firmware revision", capture.bays[0].firmwareRevision, "80.00A80")
check("serials were zeroed before committing", capture.bays[0].serial, "")

check("capacity free", capture.freeBytes, 1_294_898_933_760)
check("capacity used", capture.usedBytes, 4_667_207_208_960)
check("capacity total", capture.totalBytes, 5_962_106_142_720)
check("free plus used is total", capture.freeBytes + capture.usedBytes, capture.totalBytes)
check("status word", String(format: "0x%08X", capture.statusWord), "0x00028000")
check("severity", String(describing: capture.severity), "green")
check("no alert bits named", capture.activeAlerts.count, 0)
check("yellow threshold", capture.yellowThresholdPercent, 85)
check("red threshold", capture.redThresholdPercent, 95)
check("feature flags", String(format: "0x%llX", capture.featureFlags), "0x3")
check("spin down delay", capture.spinDownDelay, 14)
check("slot count from config", capture.slotCount, 6)
check("dual redundancy from the live numbers", String(describing: capture.redundancy), "dual")


print("\n--- redaction ---")
// The exact leak a live report produced: the enclosure name sitting inside
// FirmwareInfo, and a disk serial inside the stale tail of Options.
let name = "RAIDDEADREDEMPTION"
let serial = "WD-EXAMPLESERIAL1"
let leaky = Data(("....." + name + "...." + serial + "....").utf8)
let scrubbed = Redaction.scrub(leaky, removing: Redaction.secrets(from: [name, serial]))
check("enclosure name is gone",
      scrubbed.range(of: Data(name.utf8)) == nil, true)
check("disk serial is gone",
      scrubbed.range(of: Data(serial.utf8)) == nil, true)
check("length is unchanged", scrubbed.count, leaky.count)
check("every occurrence, not just the first",
      Redaction.scrub(Data((serial + "-" + serial).utf8),
                      removing: Redaction.secrets(from: [serial]))
          .range(of: Data(serial.utf8)) == nil, true)
check("short needles are refused",
      Redaction.secrets(from: ["ab", "abcd"]).count, 1)
check("empty secrets change nothing",
      Redaction.scrub(leaky, removing: []).count, leaky.count)

// Options declares 2304 bytes for a record of a few dozen, so its declared
// length bounds nothing and the stale event log must not be printed.
let brokenLength = Data([0x7a, 0x30, 0x09, 0x00] + [UInt8](repeating: 0x41, count: 1304))
check("a broken declared length is capped when redacting",
      Redaction.printableLength(brokenLength, redacted: true), 64)
check("and left alone when not",
      Redaction.printableLength(brokenLength, redacted: false), brokenLength.count)
let sane = Data([0x7a, 0x09, 0x00, 0x10] + [UInt8](repeating: 0, count: 1304))
check("a sane declared length is honoured",
      Redaction.printableLength(sane, redacted: true), 20)


print("\n--- feature states and the 0x33 candidate test ---")
check("bit 3 is direct-attach iSCSI",
      FeatureState.named(in: 0x08).first?.label ?? "", "Direct-attach iSCSI configured")
check("the live 5D names none of its bits", FeatureState.named(in: 0x3).count, 0)
check("and reports both as unexplained", FeatureState.unnamed(in: 0x3), [0, 1])
check("a named bit is not also unexplained", FeatureState.unnamed(in: 0x08), [])

// The words a live Drobo 5D on firmware 4.2.3 actually returned in 0x33,
// captured 2026-08-19. Word 0 agrees with all four checks, which is the reason
// to believe it is the firmware feature table.
//
// It nearly did not: the accelerator check originally tested bit 29, the
// enterprise "transactional tier", instead of bit 3, the hot data cache. That
// mislabelling ruled out the right answer on the first real capture.
func candidate(_ index: Int, _ v: UInt32,
               slots: Bool = true, accelerator: Bool = true) -> FeatureTableCandidate {
    FeatureTableCandidate(index: index, value: v,
                          answersExtendedSlots: slots, hasAccelerator: accelerator)
}
let word0 = candidate(0, 0x0000_B29E)
let word1 = candidate(1, 0x0000_0027)
let word2 = candidate(2, 0x0000_0000)

check("word 0 fits", word0.fits, true)
check("word 0 agrees with every check", word0.agreed, 4)
check("word 1 does not fit", word1.fits, false)
check("word 1 fails on the accelerator", word1.decisiveFailures.count, 1)
check("word 2 is not a table at all", word2.isPlausible, false)

check("word 0 claims extended slot info", word0.features.contains(.slotInfo2), true)
check("word 0 claims the hot data cache", word0.features.contains(.ssdCache), true)
check("word 0 does not claim Drobo Apps", word0.features.contains(.droboApps), false)
check("word 0 does not claim tiering", word0.features.contains(.transactionalTier), false)
check("word 0 has bits nothing names", word0.unnamedBits, [13, 15])

// The two labels that were swapped.
check("bit 3 is the hot data cache", FirmwareFeature.ssdCache.label, "Hot data cache")
check("bit 29 is the transactional tier",
      FirmwareFeature.transactionalTier.label, "Transactional tier")

// An enclosure with no accelerator should reject a word claiming one.
check("no accelerator, so the cache bit must be clear",
      candidate(0, 0x0000_B29E, accelerator: false).fits, false)
check("a firmware without 0x35 must not claim it",
      candidate(0, 0x0000_B29E, slots: false).fits, false)

print("\n--- which records may ever be skipped ---")
// The regression: a single failed read blacklisted the capacity record, so the
// window showed 0% used and a zero status word for a healthy array, and the
// blacklist was on disk so relaunching did not help.
let required: [ESARecord] = [.capacity, .slots, .status, .system, .config]
for r in required {
    check("\(r.label) can never be skipped", r.isOptional, false)
}
let skippable: [ESARecord] = [.diskPack, .slots2, .deviceSerial, .systemInfo]
for r in skippable {
    check("\(r.label) may be skipped", r.isOptional, true)
}
check("a skip list can never hide capacity",
      Refusals.load(model: "x").contains(ESARecord.capacity.rawValue), false)
check("more than one failure is needed", Refusals.failuresBeforeRefusing > 1, true)

// A snapshot without the capacity record must not claim to know the capacity.
let noCapacity = DroboSnapshot.decode([ESARecord.status.rawValue:
                                       bytes(fromHex: "7a0900100002800000000000")])
check("missing capacity is admitted", noCapacity.hasCapacity, false)
check("and the live capture has it", capture.hasCapacity, true)


print("\n--- honest about what is not read yet ---")
// The window fills in over two passes, so there is a real interval where the
// firmware version and per-disk health are genuinely unknown. Rendering a blank
// for that is what made a half-read window look finished.
var partial = Enclosure(id: "t", displayName: "t")
partial.snapshot = DroboSnapshot.decode([
    ESARecord.capacity.rawValue: liveRecords[0x02]!,
    ESARecord.status.rawValue:   liveRecords[0x09]!,
])
partial.readInProgress = true
check("a record that arrived is present",
      String(describing: partial.state(of: .capacity)), "present")
check("one that has not is reading",
      String(describing: partial.state(of: .firmware)), "reading")
check("and the enclosure says so", partial.isStillReading, true)

partial.refused = [ESARecord.systemInfo.rawValue]
check("a refused record is unavailable, not reading",
      String(describing: partial.state(of: .systemInfo)), "unavailable")

var full = Enclosure(id: "t", displayName: "t")
full.snapshot = DroboSnapshot.decode(liveRecords)
full.refused = Set(ESARecord.allCases.map(\.rawValue))
    .subtracting(liveRecords.keys)
check("nothing outstanding once everything is in or ruled out",
      full.isStillReading, false)
check("has() rejects a record that did not validate",
      DroboSnapshot.decode([ESARecord.capacity.rawValue: Data([0, 0, 0, 0])])
          .has(.capacity), false)


print("\n--- system info 0x33 actually decodes ---")
// This exists because the decode for 0x33 was silently absent: the field was
// declared and read but never assigned, so the card rendered its heading, its
// explanation, and then nothing at all. A present record must produce words.
let sysInfo = bytes(fromHex: "7a3300100000000020000002000000000ffffffff")
let withSysInfo = DroboSnapshot.decode([ESARecord.systemInfo.rawValue: sysInfo])
check("the record validates", withSysInfo.has(.systemInfo), true)
check("and yields three words", withSysInfo.systemInfoWords.count, 3)
check("a present record always yields candidates",
      withSysInfo.has(.systemInfo) == !withSysInfo.featureTableCandidates.isEmpty, true)
check("first word decoded", String(format: "0x%08X", withSysInfo.systemInfoWords[0]),
      "0x20000002")

print("\n--- reading ends when the read ends ---")
var mid = Enclosure(id: "t", displayName: "t")
mid.snapshot = DroboSnapshot.decode([ESARecord.capacity.rawValue: liveRecords[0x02]!])
mid.readInProgress = true
check("outstanding while a read runs",
      String(describing: mid.state(of: .firmware)), "reading")
check("and the card is shown", mid.isStillReading, true)

mid.readInProgress = false
check("once the read is over it is no answer, not reading",
      String(describing: mid.state(of: .firmware)), "noAnswer")
check("and the card goes away", mid.isStillReading, false)
check("a record that did arrive is unaffected",
      String(describing: mid.state(of: .capacity)), "present")
mid.refused = [ESARecord.firmware.rawValue]
check("a written-off record is unavailable, not no-answer",
      String(describing: mid.state(of: .firmware)), "unavailable")


print("\n--- hexdump ---")
let sample = Data([0x7a, 0x09, 0x00, 0x10, 0x00, 0x02, 0x80, 0x00])
let dumped = Hex.dump(sample, limit: sample.count)
check("offset column", dumped.hasPrefix("0000  "), true)
check("bytes in order", dumped.contains("7a 09 00 10 00 02 80 00"), true)
check("ascii gutter", dumped.contains("|z.......|"), true)
check("respects the limit", Hex.dump(sample, limit: 4).contains("80"), false)
check("empty is said so", Hex.dump(Data(), limit: 0), "(empty)")
check("indent is applied", Hex.dump(sample, limit: 4, indent: "  ").hasPrefix("  0000"), true)
// A full line must not leave a trailing newline dangling.
let sixteen = Data((0..<16).map { UInt8($0) })
check("no trailing newline on a full line",
      Hex.dump(sixteen, limit: 16).hasSuffix("\n"), false)

print(fails == 0 ? "\nall checks passed" : "\n\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
