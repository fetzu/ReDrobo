//  DroboRecords.swift
//
//  Turning raw ESA mode page records into something the UI can show.
//  The wire format is documented in docs/PROTOCOL.md; the short version is
//  MODE SENSE(10) on vendor page 0x3A, sub-page selects the record, payload is
//  big endian and starts at offset 4.

import Foundation

// MARK: - Reading big endian fields out of a record

extension Data {
    func u8(_ o: Int) -> UInt8 { indices.contains(startIndex + o) ? self[startIndex + o] : 0 }

    func u16(_ o: Int) -> UInt16 {
        guard count > o + 1 else { return 0 }
        return UInt16(u8(o)) << 8 | UInt16(u8(o + 1))
    }

    func u32(_ o: Int) -> UInt32 {
        guard count > o + 3 else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(u8(o + $1)) }
    }

    func u64(_ o: Int) -> UInt64 {
        guard count > o + 7 else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(u8(o + $1)) }
    }

    /// Fixed width text field, space and NUL padded.
    func text(_ o: Int, _ n: Int) -> String {
        guard count >= o + n else { return "" }
        let slice = self[(startIndex + o)..<(startIndex + o + n)]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Every record answers `7A <sub-page> <length hi> <length lo>`. Anything
    /// else is a different record, or not a record at all.
    func isRecord(_ subPage: UInt8) -> Bool { u8(0) == 0x7A && u8(1) == subPage }
}

// MARK: - Records

enum ESARecord: UInt8, CaseIterable {
    case config = 0x01, capacity = 0x02, slots = 0x03, luns = 0x04
    case system = 0x05, protocolVersion = 0x06, firmware = 0x08
    case status = 0x09, diskPack = 0x11, options = 0x30, options2 = 0x31
    case systemInfo = 0x33, slots2 = 0x35, deviceSerial = 0x80

    var label: String {
        switch self {
        case .config:          return "Configuration"
        case .capacity:        return "Capacity"
        case .slots:           return "Drive bays"
        case .luns:            return "Volumes"
        case .system:          return "System settings"
        case .protocolVersion: return "Protocol version"
        case .firmware:        return "Firmware"
        case .status:          return "Status"
        case .diskPack:        return "Disk pack"
        case .options:         return "Options"
        case .options2:        return "Feature flags"
        case .systemInfo:      return "System info"
        case .slots2:          return "Drive bays, extended"
        case .deviceSerial:    return "Serial number"
        }
    }

    /// Records the 5D was never seen to answer are still worth asking for, but
    /// a failure on one of these is ordinary rather than a problem.
    var isOptional: Bool {
        switch self {
        case .diskPack, .slots2, .deviceSerial, .systemInfo: return true
        default: return false
        }
    }

    /// How often a record is worth asking for.
    ///
    /// Each read is a separate round trip to the enclosure, and thirteen of them
    /// in a row is what made the window sit on a placeholder for twenty-five
    /// seconds at launch. Most of these never change while the box is powered
    /// on, so they are read once and then left alone.
    enum Tier {
        /// Needed before the window can show anything real.
        case essential
        /// Changes as the array is used, but nothing waits on it.
        case volatile
        /// Firmware version, thresholds, serial. Re-read occasionally in case
        /// something else on the network changed a setting.
        case durable
    }

    var tier: Tier {
        switch self {
        case .capacity, .slots, .status, .system, .config: return .essential
        case .slots2, .luns:                                return .volatile
        default:                                            return .durable
        }
    }

    static func pages(in tier: Tier) -> [UInt8] {
        allCases.filter { $0.tier == tier }.map(\.rawValue)
    }

    /// How long a durable record stays fresh.
    static let durableLifetime: TimeInterval = 300
}

// MARK: - One drive bay

enum BayRole: Sendable { case drive, accelerator }

struct DriveBay: Identifiable, Sendable, Equatable {
    let id: Int
    var capacityBytes: UInt64 = 0
    var model = ""
    var role: BayRole = .drive

    // Everything below comes from the extended slot record, sub-page 0x35,
    // and is absent on firmware that does not answer it.
    var extended = false
    var health: DiskHealth = .good
    var slotStatus: UInt8 = 0
    var errorCount: UInt16 = 0
    var kind: DiskKind = .unknown
    var temperatureC: Int?
    var lifeRemainingPercent: Int?
    var rotationalSpeed: UInt8 = 0
    var firmwareRevision = ""
    var serial = ""
    var managedCapacityBytes: UInt64 = 0

    var isAccelerator: Bool { role == .accelerator }
    var isEmpty: Bool { capacityBytes == 0 }

    /// Bays are numbered from one; the accelerator is not a bay and has no
    /// number. Slot order is the order the enclosure reports, which on a 5D is
    /// top to bottom with the mSATA last.
    var label: String { isAccelerator ? "Accelerator" : "Bay \(id + 1)" }

    /// Drive makers sell in decimal TB, so show bays that way. Sub terabyte
    /// devices, meaning the accelerator, read better in GB.
    var displayCapacity: String {
        guard !isEmpty else { return "—" }
        let oneTB: UInt64 = 1_000_000_000_000
        return capacityBytes < oneTB
            ? String(format: "%.0f GB", Double(capacityBytes) / 1e9)
            : String(format: "%.0f TB", Double(capacityBytes) / 1e12)
    }

    /// Only ever true when the extended record said so. An enclosure that does
    /// not answer 0x35 reports every bay as good, which would be a lie, so the
    /// UI checks `extended` before showing health at all.
    var needsAttention: Bool { extended && health.isTrouble }
}

// MARK: - Everything the enclosure will tell us, decoded

struct DroboSnapshot: Sendable {
    var name = ""
    var serial = ""
    var slotCount = 0
    var maxLuns = 0
    var lunCount = 0

    var freeBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    /// Capacity the array is carrying without redundancy behind it.
    var unprotectedTotalBytes: UInt64 = 0

    var bays: [DriveBay] = []
    var hasExtendedSlots = false

    /// The enclosure stores LOCAL wall clock in this field, not UTC, with the
    /// offset kept separately. Do not convert it.
    var deviceClock = ""
    var gmtOffsetMinutes = 0

    var firmwareVersion = ""
    var firmwareBuild: UInt32 = 0
    var firmwareBuiltOn = ""
    var platform = ""
    var protocolVersion = ""

    var statusWord: UInt32 = 0
    var diskPackStatus: UInt32 = 0
    var relayoutCount: UInt32 = 0
    var yellowThresholdPercent = 0
    var redThresholdPercent = 0
    var featureFlags: UInt64 = 0
    var spinDownDelay: UInt16 = 0

    /// The three unnamed big-endian words of SystemInfo (`0x33`). One of them
    /// is very likely the firmware feature table: `ESAFirmwareInfo::parse`
    /// never writes the field its own `getFeatureTable()` reads, so the table
    /// arrives from somewhere else, and this record is the only candidate that
    /// is the right shape. See `featureTableCandidates`.
    var systemInfoWords: [UInt32] = []

    var raw: [UInt8: Data] = [:]

    // MARK: Derived

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    var usedPercent: Int { Int((usedFraction * 100).rounded()) }

    var severity: DroboStatus.Severity { DroboStatus.severity(of: UInt64(statusWord)) }

    /// Bits that are set and that Drobo's own alert code has a name for.
    var activeAlerts: [StatusBit] { DroboStatus.named(UInt64(statusWord)) }

    var isRelayouting: Bool {
        relayoutCount > 0 || UInt64(statusWord) & (1 << 9) != 0
    }

    enum Health: Sendable { case good, warning, critical, unknown }

    /// The enclosure's own verdict first, capacity second. Drobo's severity
    /// masks are authoritative about the array; the percentage is only about
    /// how full it is.
    var health: Health {
        switch severity {
        case .red:    return .critical
        case .yellow: return .warning
        case .green:
            if usedPercent >= 95 { return .critical }
            if yellowThresholdPercent > 0 && usedPercent >= yellowThresholdPercent {
                return .warning
            }
            return .good
        }
    }

    var healthLabel: String {
        if isRelayouting { return "Rebuilding" }
        if let worst = activeAlerts.first { return worst.name }
        switch health {
        case .good:     return "Good"
        case .warning:  return "Space low"
        case .critical: return "Nearly full"
        case .unknown:  return "Unknown"
        }
    }

    var driveBays: [DriveBay] { bays.filter { !$0.isAccelerator } }
    var accelerator: DriveBay? { bays.first { $0.isAccelerator } }
    var populatedBays: [DriveBay] { driveBays.filter { !$0.isEmpty } }

    var rawInstalledBytes: UInt64 { driveBays.reduce(0) { $0 + $1.capacityBytes } }

    /// What BeyondRAID is holding back. Everything the disks provide, minus
    /// everything the array offers, is redundancy plus overhead.
    var reservedForProtectionBytes: UInt64 {
        let offered = totalBytes + unprotectedTotalBytes
        return rawInstalledBytes > offered ? rawInstalledBytes - offered : 0
    }

    /// How much of the raw capacity survives as usable space.
    var usableFraction: Double {
        rawInstalledBytes > 0
            ? Double(totalBytes + unprotectedTotalBytes) / Double(rawInstalledBytes)
            : 0
    }

    /// Single or dual disk redundancy, worked out from the capacities.
    ///
    /// BeyondRAID holds back the largest disk for single redundancy and the two
    /// largest for dual, so the ratio of what is held back to those two figures
    /// picks the level out. The two hypotheses are a factor of two apart, which
    /// is why a tight window still leaves no room to confuse them.
    ///
    /// Checked against the 5D this app was built on, which is known to be
    /// running dual redundancy:
    ///
    ///     raw 2/2/4/2/4 TB      14 002 770 862 080
    ///     usable                 5 962 106 142 720
    ///     held back              8 040 664 719 360
    ///     held / largest                    2.0098   <- not single
    ///     held / two largest                1.0049   <- dual, to 0.5%
    ///
    /// It is still a derivation. No decoded record carries the level, and
    /// nothing Drobo shipped reads one either — Dashboard's own checkbox comes
    /// through DDService's device model rather than a mode page field. The UI
    /// says where the number comes from.
    enum Redundancy: Sendable { case single, dual, none, unknown }

    var redundancy: Redundancy {
        let disks = populatedBays.map(\.capacityBytes).sorted(by: >)
        guard !disks.isEmpty else { return .unknown }
        let reserved = Double(reservedForProtectionBytes)
        guard reserved > 0 else { return .none }

        let largest = Double(disks[0])
        let twoLargest = largest + Double(disks.count > 1 ? disks[1] : 0)
        guard largest > 0 else { return .unknown }

        if disks.count > 2, abs(reserved / twoLargest - 1) <= 0.15 { return .dual }
        if abs(reserved / largest - 1) <= 0.15 { return .single }
        return .unknown
    }

    var redundancyLabel: String {
        switch redundancy {
        case .single:  return "Single disk redundancy"
        case .dual:    return "Dual disk redundancy"
        case .none:    return "No redundancy"
        case .unknown: return "Not determinable from the capacities"
        }
    }

    /// How well the numbers fit, so the UI can be honest about a marginal call.
    var redundancyFit: Double? {
        let disks = populatedBays.map(\.capacityBytes).sorted(by: >)
        guard !disks.isEmpty, reservedForProtectionBytes > 0 else { return nil }
        let reserved = Double(reservedForProtectionBytes)
        switch redundancy {
        case .single: return reserved / Double(disks[0])
        case .dual:   return reserved / (Double(disks[0]) + Double(disks.count > 1 ? disks[1] : 0))
        default:      return nil
        }
    }

    /// Whether the array could lose a disk right now. This one is a fact: it is
    /// bit 6 of the status word.
    var isProtected: Bool { UInt64(statusWord) & (1 << 6) == 0 }

    /// Whether a given record was actually read and validated.
    func has(_ record: ESARecord) -> Bool {
        guard let d = raw[record.rawValue] else { return false }
        return d.isRecord(record.rawValue)
    }

    /// Whether the capacity record actually decoded. Without it every figure
    /// derived from it is zero, and showing "0% used" for an array that is
    /// three-quarters full is worse than showing nothing.
    var hasCapacity = false

    /// Test each word of SystemInfo against what this enclosure demonstrably
    /// does, to see whether any of them is the firmware feature table.
    ///
    /// Two of the fourteen named bits can be checked against observable fact:
    /// if the enclosure answered sub-page `0x35` it supports extended slot info
    /// (bit 1), and if it has an mSATA accelerator it has the hot data cache
    /// (bit 3). Bit 29 is a *different* feature — the enterprise transactional
    /// tier — and using it for the accelerator is what wrongly ruled out the
    /// right answer the first time this ran on real hardware.
    var featureTableCandidates: [FeatureTableCandidate] {
        systemInfoWords.enumerated().map { index, word in
            FeatureTableCandidate(index: index, value: word,
                                  answersExtendedSlots: hasExtendedSlots,
                                  hasAccelerator: accelerator != nil)
        }
    }

    // MARK: Parsing

    /// Which slot, if any, is the mSATA accelerator rather than a drive bay.
    ///
    /// A 5D reports six slots: five bays then the accelerator. There is no flag
    /// for it in the record, so it has to be inferred, and the obvious rule —
    /// "anything under 500 GB" — misfires on a small disk sitting in a real bay
    /// and on every model that has no accelerator at all. Requiring it to be
    /// the last slot *and* far smaller than everything else costs nothing and
    /// is wrong far less often. With the extended record the disk type is
    /// known, which settles it properly.
    static func acceleratorSlot(in capacities: [UInt64], kinds: [DiskKind] = []) -> Int? {
        guard let last = capacities.last, capacities.count > 1 else { return nil }
        guard last > 0 else { return nil }
        let others = capacities.dropLast().filter { $0 > 0 }
        guard let smallest = others.min() else { return nil }

        // The reliable answer, when the enclosure told us the disk types: an SSD
        // in the last slot alongside hard disks is the cache, not a bay.
        if kinds.count == capacities.count, kinds[kinds.count - 1] == .ssd {
            let othersAreDisks = kinds.dropLast().enumerated()
                .contains { capacities[$0.offset] > 0 && $0.element == .hdd }
            if othersAreDisks && last < smallest { return capacities.count - 1 }
        }

        guard last < 512_000_000_000 else { return nil }
        return last * 2 <= smallest ? capacities.count - 1 : nil
    }

    /// The model field carries the interface marker glued to the end, so a
    /// live 5D reports "WDC WD20EZRX-00DSATA" and "M4-CT128M4SSD3  SATA".
    /// Both records do it; only the older one was being cleaned up.
    static func modelName(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: "SATA").first ?? raw
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : trimmed
    }

    static func decode(_ records: [UInt8: Data]) -> DroboSnapshot {
        var s = DroboSnapshot()
        s.raw = records

        func record(_ r: ESARecord) -> Data? {
            guard let d = records[r.rawValue], d.isRecord(r.rawValue) else { return nil }
            return d
        }

        if let d = record(.config) {
            s.slotCount = Int(d.u8(4))
            s.maxLuns   = Int(d.u8(6))
        }
        if let d = record(.capacity) {
            s.hasCapacity = true
            s.freeBytes  = d.u64(4)
            s.usedBytes  = d.u64(12)
            s.totalBytes = d.u64(20)
            s.unprotectedTotalBytes = d.u64(28)
        }
        if let d = record(.luns) {
            s.lunCount = Int(d.u8(4))
        }
        if let d = record(.system) {
            let fmt = DateFormatter()
            fmt.timeZone = TimeZone(identifier: "UTC")   // print the device's own clock face
            fmt.dateFormat = "d MMM yyyy 'at' HH:mm"
            s.deviceClock = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(d.u32(4))))
            s.gmtOffsetMinutes = Int(d.u16(8))
            s.name = d.text(10, 32)
        }
        if let d = record(.protocolVersion) {
            s.protocolVersion = "\(d.u8(4)).\(d.u8(5))"
        }
        if let d = record(.firmware) {
            s.firmwareVersion = d.text(58, 8)
            s.firmwareBuild   = d.u32(206)
            s.firmwareBuiltOn = d.text(10, 24)
            s.platform        = d.text(42, 16)
        }
        if let d = record(.status) {
            s.statusWord     = d.u32(4)
            s.relayoutCount  = d.u32(8)
            s.diskPackStatus = d.u32(12)
        }
        if let d = record(.options) {
            s.yellowThresholdPercent = Int(d.u8(4))
            s.redThresholdPercent    = Int(d.u8(5))
        }
        if let d = record(.options2) {
            s.featureFlags   = d.u64(4)
            s.spinDownDelay  = d.u16(12)
        }
        if let d = record(.systemInfo) {
            // Three unnamed big-endian words. See featureTableCandidates.
            s.systemInfoWords = [d.u32(8), d.u32(12), d.u32(16)]
        }
        // DiskPackInfo (0x11) is read and kept raw but not decoded. Its parse()
        // is a loop over a per-slot structure, so the single pack-level name and
        // ID this once assumed are not where they were assumed to be, and there
        // is no capture to check a real layout against. The bytes are in the
        // diagnostics report for whoever gets one.
        if let d = record(.deviceSerial) {
            // Sub-page 0x80 is claimed by two records in Drobo's own code, so
            // only take this one when it actually looks like a serial number.
            let candidate = d.text(4, 24)
            if candidate.hasPrefix("DR") { s.serial = candidate }
        }

        s.bays = decodeBays(records)
        s.hasExtendedSlots = s.bays.contains(where: \.extended)
        return s
    }

    /// The plain slot record is the fallback; the extended one wins where the
    /// firmware answers it, because it carries health, serials and temperature.
    private static func decodeBays(_ records: [UInt8: Data]) -> [DriveBay] {
        var bays: [DriveBay] = []

        if let d = records[ESARecord.slots2.rawValue], d.isRecord(ESARecord.slots2.rawValue) {
            let n = Int(d.u8(8))
            // 12 byte header, then 108 bytes per slot.
            for i in 0..<n {
                let e = 12 + i * 108
                guard d.count >= e + 108 else { break }
                var bay = DriveBay(id: Int(d.u8(e)))
                bay.extended            = true
                bay.slotStatus          = d.u8(e + 1)
                bay.errorCount          = d.u16(e + 2)
                bay.health              = DiskHealth(state: d.u32(e + 4))
                bay.rotationalSpeed     = d.u8(e + 11)
                bay.kind                = DiskKind(type: d.u8(e + 8),
                                                   rotationalSpeed: bay.rotationalSpeed)
                bay.model               = Self.modelName(d.text(e + 12, 44))
                bay.firmwareRevision    = d.text(e + 56, 12)
                bay.serial              = d.text(e + 68, 24)
                bay.capacityBytes       = d.u64(e + 92)
                bay.managedCapacityBytes = d.u64(e + 100)

                let temperature = Int(d.u8(e + 9))
                bay.temperatureC = (temperature > 0 && temperature < 120) ? temperature : nil
                // Wear only means something on flash. Every hard disk in the
                // live capture reports 100, which is a placeholder rather than
                // a measurement, and showing it invites the wrong conclusion.
                let life = Int(d.u8(e + 10))
                bay.lifeRemainingPercent =
                    (bay.kind == .ssd && life > 0 && life <= 100) ? life : nil

                bays.append(bay)
            }
        }

        if bays.isEmpty, let d = records[ESARecord.slots.rawValue],
           d.isRecord(ESARecord.slots.rawValue) {
            let n = Int(d.u8(4))
            for i in 0..<n {
                let e = 5 + i * 72
                var bay = DriveBay(id: i)
                bay.capacityBytes = d.u64(e + 3)
                bay.managedCapacityBytes = d.u64(e + 11)
                bay.model = Self.modelName(d.text(e + 20, 32))
                bay.firmwareRevision = d.text(e + 52, 16)
                bays.append(bay)
            }
        }

        let accelerator = acceleratorSlot(in: bays.map(\.capacityBytes),
                                          kinds: bays.map(\.kind))
        for i in bays.indices where i == accelerator { bays[i].role = .accelerator }
        return bays
    }
}

// MARK: - Formatting

enum Fmt {
    /// Drobo Dashboard labels TiB as TB. Match that so the numbers agree with
    /// what people are used to seeing, and say TB.
    static func tib(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1_099_511_627_776
        return String(format: v < 10 ? "%.2f TB" : "%.1f TB", v)
    }

    /// Decimal TB, which is how disks are sold and labelled.
    static func diskTB(_ bytes: UInt64) -> String {
        bytes < 1_000_000_000_000
            ? String(format: "%.0f GB", Double(bytes) / 1e9)
            : String(format: "%.1f TB", Double(bytes) / 1e12)
    }
}
