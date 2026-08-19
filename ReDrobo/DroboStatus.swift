//  DroboStatus.swift
//
//  The meanings behind the numbers, recovered from Drobo's own DDService64d
//  (Dashboard 3.6.1, build 115880) rather than guessed. See docs/PROTOCOL.md
//  for where each table comes from and how confident it is.

import Foundation

// MARK: - The status word

/// One bit of the ESA status word, with the name Drobo's own alert code used.
struct StatusBit: Identifiable, Sendable {
    let bit: Int
    let name: String
    let detail: String
    var id: Int { bit }
    var mask: UInt64 { 1 << UInt64(bit) }
}

enum DroboStatus {

    /// Recovered from AlertMailer::GetEventIDForStatus, which switches on one
    /// bit at a time and names each. Bits absent from that switch are absent
    /// here too, and are reported as unknown rather than invented.
    static let bits: [StatusBit] = [
        .init(bit: 1,  name: "Red threshold exceeded",
              detail: "Free space is below the enclosure's red threshold."),
        .init(bit: 2,  name: "Yellow threshold exceeded",
              detail: "Free space is below the enclosure's yellow threshold."),
        .init(bit: 3,  name: "No disks",
              detail: "The enclosure has no disks in it."),
        .init(bit: 4,  name: "Bad disk",
              detail: "At least one disk has failed."),
        .init(bit: 5,  name: "Too many missing disks",
              detail: "More disks are missing than the pack can survive."),
        .init(bit: 6,  name: "No redundancy",
              detail: "The array cannot survive a disk failure right now."),
        .init(bit: 9,  name: "Relayout in progress",
              detail: "The array is redistributing data across the pack."),
        .init(bit: 11, name: "Mismatched disks",
              detail: "The pack contains disks it did not expect."),
        .init(bit: 18, name: "Incompatible disk pack",
              detail: "This pack was written by firmware this unit cannot read."),
        .init(bit: 20, name: "Power supply failure",
              detail: "A power supply has failed."),
        .init(bit: 21, name: "Fan partial failure",
              detail: "A fan is degraded."),
        .init(bit: 22, name: "Fan failure",
              detail: "A fan has failed."),
        .init(bit: 23, name: "Fan missing",
              detail: "A fan is not present."),
        .init(bit: 25, name: "Hybrid tiering",
              detail: "Data is moving between the SSD tier and the disks."),
        .init(bit: 32, name: "DroboShare alert",
              detail: "An attached DroboShare needs attention."),
        .init(bit: 33, name: "Drive added",
              detail: "A drive has been inserted."),
        .init(bit: 34, name: "Drive removed",
              detail: "A drive has been taken out."),
        .init(bit: 35, name: "Dual disk redundancy changed",
              detail: "The redundancy setting has been changed."),
        .init(bit: 36, name: "Volume usage over limit",
              detail: "A volume has exceeded its usable limit."),
        .init(bit: 37, name: "All volumes over limit",
              detail: "Every volume has exceeded its usable limit."),
        .init(bit: 38, name: "Target login",
              detail: "An iSCSI target login state changed."),
        .init(bit: 39, name: "Relayout complete",
              detail: "The array has finished redistributing data."),
        .init(bit: 41, name: "Three SSDs and a disk required",
              detail: "This configuration needs three SSDs plus a hard disk."),
    ]

    private static let byBit = Dictionary(uniqueKeysWithValues: bits.map { ($0.bit, $0) })

    /// Straight out of ESAAlertHistory::getSeverityForStatus:
    ///
    ///     testl $0x14C4187A, %edi      -> anything here means red
    ///     andq  $0x36002300244, %rdi   -> anything left means yellow
    ///                                  -> otherwise green
    ///
    /// The red mask is tested 32 bits wide, exactly as the original does it.
    static let redMask: UInt32 = 0x14C4_187A
    static let yellowMask: UInt64 = 0x360_0230_0244

    enum Severity: Sendable { case red, yellow, green }

    static func severity(of status: UInt64) -> Severity {
        if UInt32(truncatingIfNeeded: status) & redMask != 0 { return .red }
        if status & yellowMask != 0 { return .yellow }
        return .green
    }

    /// Every bit that is set, named where Drobo named it.
    static func decompose(_ status: UInt64) -> [(bit: Int, name: String?, detail: String?)] {
        (0..<64).compactMap { bit in
            guard status & (1 << UInt64(bit)) != 0 else { return nil }
            let known = byBit[bit]
            return (bit, known?.name, known?.detail)
        }
    }

    static func named(_ status: UInt64) -> [StatusBit] {
        bits.filter { status & $0.mask != 0 }
    }
}

// MARK: - Per-disk state

/// DDUtils::GetDiskState masks the disk state with 0xF and switches on 0...3.
enum DiskHealth: Int, Sendable, CaseIterable {
    case good = 0, healed = 1, warning = 2, failed = 3

    init(state: UInt32) { self = DiskHealth(rawValue: Int(state & 0xF)) ?? .good }

    var label: String {
        switch self {
        case .good:    return "Good"
        case .healed:  return "Healed"
        case .warning: return "Warning"
        case .failed:  return "Failed"
        }
    }

    /// Healed means it recovered from an error and is being watched, which is
    /// worth showing differently from plain good.
    var isTrouble: Bool { self == .warning || self == .failed }
}

enum DiskKind: Sendable {
    case hdd, ssd, unknown

    /// From a live 5D on firmware 4.2.3: the type byte is 0 for all five WD
    /// hard disks and 4 for the mSATA SSD.
    ///
    /// The rotational speed byte is NOT a usable substitute, which is what the
    /// first version of this got wrong. On that same capture it reads 0 for the
    /// WD20EZRX drives, 27 for the WD40EFRX and WD20EFRX, and 1 for the SSD —
    /// so "no rotation means solid state" labelled two hard disks as SSDs and
    /// the actual SSD as a hard disk.
    init(type: UInt8, rotationalSpeed: UInt8) {
        if type & 0x04 != 0 { self = .ssd }
        else if type == 0   { self = .hdd }
        else                { self = .unknown }
    }

    var label: String {
        switch self {
        case .hdd:     return "Hard disk"
        case .ssd:     return "SSD"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Firmware feature table

/// What the enclosure's firmware supports. Recovered from every call site of
/// DroboDevice::IsFirmwareFeatureSupported in Drobo Dashboard.
///
/// Note this is the *supported* table, which is not the same field as
/// Options2's featureOnOffStates (what is switched on). Where that one lives
/// is still unknown, so ReDrobo shows its bits without naming them.
enum FirmwareFeature: UInt32, CaseIterable, Sendable {
    case slotInfo2          = 0x0000_0002
    case backgroundFileCheck = 0x0000_0004
    case ssdCache           = 0x0000_0008
    case activationMode     = 0x0000_0010
    case droboApps          = 0x0000_0020
    case volumeResize       = 0x0000_0080
    case backupVolume       = 0x0000_0200
    case userEventLogs      = 0x0000_0800
    case virtualMachines    = 0x0000_1000
    case lightDimming       = 0x0001_0000
    case extendedLunInfo    = 0x0080_0000
    case scsi4Reservations  = 0x0800_0000
    case blinkLight         = 0x1000_0000
    case transactionalTier  = 0x2000_0000

    var label: String {
        switch self {
        case .slotInfo2:           return "Extended slot info"
        case .backgroundFileCheck: return "Background file check"
        case .ssdCache:            return "Hot data cache"
        case .activationMode:      return "Activation mode"
        case .droboApps:           return "Drobo Apps"
        case .volumeResize:        return "Volume resize"
        case .backupVolume:        return "Backup volume"
        case .userEventLogs:       return "Event logs"
        case .virtualMachines:     return "Virtual machines"
        case .lightDimming:        return "Light dimming"
        case .extendedLunInfo:     return "Extended volume info"
        case .scsi4Reservations:   return "SCSI-4 reservations"
        case .blinkLight:          return "Locator light"
        case .transactionalTier:   return "Transactional tier"
        }
    }

    static func present(in table: UInt32) -> [FirmwareFeature] {
        allCases.filter { table & $0.rawValue != 0 }
    }
}

/// Bits of `Options2`'s `featureOnOffStates` — what is switched *on*, as
/// opposed to `FirmwareFeature`, which is what the box can do.
///
/// Exactly one bit is decoded by anything Drobo shipped.
/// `ESABlockDevice::doPollESAUpdate` tests bit 3 and only then bothers to read
/// the direct-attach iSCSI address and subnet mask out of the same record.
/// Every other consumer copies the value whole: `getProConfig` passes the raw
/// 64 bits through, `constructHSESAUpdate` stores it untouched, and the string
/// `mFirmwareFeatureStates` sits in the Dashboard binary referenced by nothing.
enum FeatureState: UInt64, CaseIterable, Sendable {
    case directAttachISCSI = 0x08

    var label: String {
        switch self {
        case .directAttachISCSI: return "Direct-attach iSCSI configured"
        }
    }

    static func named(in states: UInt64) -> [FeatureState] {
        allCases.filter { states & $0.rawValue != 0 }
    }

    /// The bits that are set and that nothing anywhere explains.
    static func unnamed(in states: UInt64) -> [Int] {
        let known = allCases.reduce(UInt64(0)) { $0 | $1.rawValue }
        return (0..<64).filter { states & ~known & (1 << UInt64($0)) != 0 }
    }
}

/// One of SystemInfo's three unnamed words, judged against what the enclosure
/// is observably doing.
///
/// Two of the criteria are facts about the hardware in front of us and settle
/// the matter; two are inferences about what a direct-attached desktop
/// enclosure is, and only add or subtract confidence.
struct FeatureTableCandidate: Identifiable, Sendable {

    struct Criterion: Identifiable, Sendable {
        let id: Int
        let feature: FirmwareFeature
        let because: String
        let expected: Bool
        let actual: Bool
        /// True when the expectation is an observed fact rather than a guess.
        let decisive: Bool

        var agrees: Bool { expected == actual }
        var summary: String {
            "\(feature.label) is \(actual ? "set" : "clear"), "
          + "expected \(expected ? "set" : "clear") — \(because)"
        }
    }

    let index: Int
    let value: UInt32
    let criteria: [Criterion]

    var id: Int { index }

    init(index: Int, value: UInt32,
         answersExtendedSlots: Bool, hasAccelerator: Bool) {
        self.index = index
        self.value = value
        func isSet(_ f: FirmwareFeature) -> Bool { value & f.rawValue != 0 }
        criteria = [
            .init(id: 0, feature: .slotInfo2,
                  because: answersExtendedSlots
                      ? "sub-page 0x35 does answer on this enclosure"
                      : "sub-page 0x35 does not answer on this enclosure",
                  expected: answersExtendedSlots, actual: isSet(.slotInfo2),
                  decisive: true),
            .init(id: 1, feature: .ssdCache,
                  because: hasAccelerator
                      ? "an mSATA accelerator is fitted"
                      : "no accelerator is fitted",
                  expected: hasAccelerator, actual: isSet(.ssdCache),
                  decisive: true),
            .init(id: 2, feature: .droboApps,
                  because: "Drobo Apps were a NAS feature, and this is direct attached",
                  expected: false, actual: isSet(.droboApps), decisive: false),
            .init(id: 3, feature: .transactionalTier,
                  because: "tiering was an enterprise feature, separate from the cache",
                  expected: false, actual: isSet(.transactionalTier), decisive: false),
        ]
    }

    var features: [FirmwareFeature] { FirmwareFeature.present(in: value) }

    /// Bits that are set and that no recovered accessor names.
    var unnamedBits: [Int] {
        let known = FirmwareFeature.allCases.reduce(UInt32(0)) { $0 | $1.rawValue }
        return (0..<32).filter { value & ~known & (1 << UInt32($0)) != 0 }
    }

    /// A word of all zeros or all ones says nothing, whatever the bits do.
    var isPlausible: Bool { value != 0 && value != .max }

    var agreed: Int { criteria.filter(\.agrees).count }
    var decisiveFailures: [Criterion] { criteria.filter { $0.decisive && !$0.agrees } }
    var fits: Bool { isPlausible && decisiveFailures.isEmpty }

    var verdict: String {
        guard isPlausible else { return "Not a feature table: no bits set, or all of them." }
        if fits {
            let soft = criteria.filter { !$0.decisive && !$0.agrees }.count
            return soft == 0
                ? "Agrees with all \(criteria.count) checks. This is the candidate."
                : "Agrees with both decisive checks and \(agreed) of \(criteria.count) overall."
        }
        return "Ruled out: " + decisiveFailures.map(\.summary).joined(separator: "; ")
    }
}
