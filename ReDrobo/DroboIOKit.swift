//  DroboIOKit.swift
//
//  Everything that touches IOKit. Finding the driver's services, opening one
//  user client per enclosure, reading the ten ESA records, and working out
//  which mounted volume belongs to which enclosure.
//
//  No io_object_t escapes this file. Every function that opens one closes it
//  before returning and hands back plain values, which is what lets the whole
//  lot run off the main actor.

import Foundation
import IOKit
import Darwin

let kDextBundleID = "org.redrobo.ReDrobo.DroboDext"
let kRecordSize = 1308

private let kSelectorReadRecord: UInt32 = 0

// MARK: - Errors

enum DroboError: LocalizedError {
    case openFailed(kern_return_t)
    case readFailed(UInt8, kern_return_t)

    var errorDescription: String? {
        switch self {
        case .openFailed(let kr):
            return String(format: "Could not open the driver (0x%08x).", kr)
        case .readFailed(let page, let kr):
            return String(format: "Record 0x%02x could not be read (0x%08x).", page, kr)
        }
    }
}

// MARK: - Registry odds and ends

private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
}

private func regString(_ entry: io_registry_entry_t, _ key: String) -> String? {
    let value = property(entry, key)
    if let s = value as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    if let d = value as? Data {
        let t = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    return nil
}

private func entryID(_ entry: io_registry_entry_t) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(entry, &id)
    return id
}

/// Walk up the provider chain until `probe` answers. The USB serial number
/// lives several levels above the SCSI nub, so this is how an enclosure gets an
/// identity that survives a replug.
private func lookUp<T>(from start: io_registry_entry_t,
                       limit: Int = 20,
                       _ probe: (io_registry_entry_t) -> T?) -> T? {
    var entry = start
    IOObjectRetain(entry)
    defer { IOObjectRelease(entry) }

    for _ in 0..<limit {
        if let found = probe(entry) { return found }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
              parent != 0 else { return nil }
        IOObjectRelease(entry)
        entry = parent
    }
    return nil
}

/// Depth first over everything below `start`. Return false from `body` to stop.
private func lookDown(from start: io_registry_entry_t,
                      _ body: (io_registry_entry_t) -> Bool) {
    var iter: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(start, kIOServicePlane,
                                        IOOptionBits(kIORegistryIterateRecursively),
                                        &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }

    while case let child = IOIteratorNext(iter), child != 0 {
        defer { IOObjectRelease(child) }
        if !body(child) { return }
    }
}

/// Run `body` over every service matching each dictionary, once per distinct
/// registry entry. IOServiceGetMatchingServices consumes the dictionary, which
/// is why they are built fresh here rather than passed in.
private func forEachService(matching dictionaries: [CFMutableDictionary?],
                            _ body: (io_service_t) -> Void) {
    var seen = Set<UInt64>()
    for dict in dictionaries {
        guard let dict else { continue }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter) == KERN_SUCCESS
        else { continue }
        defer { IOObjectRelease(iter) }

        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            if seen.insert(entryID(svc)).inserted { body(svc) }
        }
    }
}

/// The dext calls RegisterService(). Depending on how the registry names it,
/// either class or name matching finds it, so both are always tried.
private func droboDextMatches() -> [CFMutableDictionary?] {
    [IOServiceMatching("DroboDext"), IOServiceNameMatching("DroboDext")]
}

// MARK: - The user client

private struct Connection {
    private var connection: io_connect_t = 0

    mutating func open(_ service: io_service_t) throws {
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw DroboError.openFailed(kr) }
    }

    mutating func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    func read(record page: UInt8) throws -> Data {
        var input = UInt64(page)
        var out = [UInt8](repeating: 0, count: kRecordSize)
        var outSize = kRecordSize

        let kr = out.withUnsafeMutableBytes { raw -> kern_return_t in
            IOConnectCallMethod(connection, kSelectorReadRecord,
                                &input, 1, nil, 0, nil, nil,
                                raw.baseAddress, &outSize)
        }
        guard kr == KERN_SUCCESS else { throw DroboError.readFailed(page, kr) }
        return Data(out.prefix(outSize))
    }
}

// MARK: - What one read pass produces

/// One enclosure the driver is currently bound to, as read in a single pass.
struct EnclosureReading: Sendable {
    var entryID: UInt64 = 0
    var providerID: UInt64 = 0

    /// Straight off the INQUIRY strings the nub publishes.
    var vendor = ""
    var product = ""
    var revision = ""

    /// Stamped into the personality by the driver's Makefile, so this is the
    /// build that is *running*, not the one that is installed. They differ
    /// until the Mac is restarted, which is the trap this exists to expose.
    var driverBuild: String?
    var personality: String?

    var usbSerial: String?
    var wholeDisk: String?

    var records: [UInt8: Data] = [:]
    var error: String?

    /// Sub-pages skipped this pass because they are already believed absent.
    var refused: Set<UInt8> = []
    /// Sub-pages asked for and not answered this pass. A failure, which is not
    /// the same thing as a refusal: one bad read while the driver is settling
    /// is no evidence that a firmware lacks the record.
    var failed: Set<UInt8> = []
    /// Sub-pages asked for and answered this pass.
    var succeeded: Set<UInt8> = []

    /// How long each record actually took, and the whole enclosure with it.
    /// This is the only honest way to answer "what does a poll cost"; the
    /// numbers differ per enclosure, per firmware and per cable.
    var timings: [UInt8: TimeInterval] = [:]
    var duration: TimeInterval = 0

    var slowestRecord: (page: UInt8, seconds: TimeInterval)? {
        timings.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    /// Which records a firmware refuses is a property of the model, not of this
    /// particular box, so that is what the memory is keyed on.
    var modelKey: String { "\(vendor)|\(product)" }
}

/// The cheap half of a poll: what is bound and what is attached, with no SCSI
/// traffic at all. Answers in microseconds, which is what lets the UI say
/// something useful before the reads come back.
struct QuickScan: Sendable {
    var driverBound = false
    var devices: [ScannedDevice] = []
    var duration: TimeInterval = 0
}

/// The Vendor Identification strings Drobo shipped enclosures under. Two of
/// them say nothing about Drobo at all, which is why the scan cannot simply
/// look for the word: a Drobo S Gen 2 answers INQUIRY as "USB 3.0", and the
/// oldest units as "TRUSTED". Straight out of the kext's own personalities.
enum DroboIdentity {
    /// Vendor alone is too loose for the two generic ones, so those have to
    /// match a product string as well.
    static let looseVendors: Set<String> = ["drobo"]
    static let strictPairs: Set<String> = [
        "trusted|usb mass storage",
        "trusted|mass storage",
        "usb 3.0|drobo s - gen 2",
    ]

    static func isDrobo(vendor: String, product: String) -> Bool {
        let v = vendor.lowercased().trimmingCharacters(in: .whitespaces)
        let p = product.lowercased().trimmingCharacters(in: .whitespaces)
        if looseVendors.contains(v) { return true }
        if p.contains("drobo") { return true }
        return strictPairs.contains("\(v)|\(p)")
    }
}

/// A Drobo the system can see, whether or not our driver claimed it. This is
/// what separates "no driver" from "no enclosure", and it is also how an
/// unsupported model reports itself well enough to be added by hand.
struct ScannedDevice: Sendable, Identifiable, Hashable {
    var id: UInt64
    var vendor: String
    var product: String
    var revision: String
    var claimed: Bool

    var modelKey: String { "\(vendor)|\(product)" }
}

/// Which sub-pages a given model of enclosure refuses, remembered between
/// launches. Each refusal costs a round trip to discover, and the answer never
/// changes for a given firmware, so rediscovering them every launch was pure
/// latency at exactly the moment the app should feel quickest.
enum Refusals {
    private static let key = "refusedRecords"
    private static let versionKey = "refusedRecordsVersion"

    /// Bumped when the rules for what belongs in this store change. Version 1
    /// blacklisted a record after a single failed read, including records the
    /// app cannot work without, so anything stored under it is untrustworthy
    /// and is thrown away rather than migrated.
    private static let version = 2

    private static var all: [String: [Int]] {
        get {
            if UserDefaults.standard.integer(forKey: versionKey) != version { reset() }
            return UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.set(version, forKey: versionKey)
        }
    }

    /// How many polls in a row a record has to fail before it is believed to be
    /// genuinely absent. One failure is a hiccup; three is a firmware that does
    /// not have the record.
    static let failuresBeforeRefusing = 3

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(version, forKey: versionKey)
    }

    static func load(model: String) -> Set<UInt8> {
        Set((all[model] ?? []).compactMap { UInt8(exactly: $0) })
            .filter { ESARecord(rawValue: $0)?.isOptional == true }
    }

    static func save(model: String, pages: Set<UInt8>) {
        guard !model.isEmpty, model != "|" else { return }
        var map = all
        let sorted = pages.map(Int.init).sorted()
        guard map[model] != sorted else { return }
        map[model] = sorted
        all = map
    }
}

// MARK: - Reading

enum DroboIOKit {


    /// Registry only. No user client is opened and no CDB is sent, so this is
    /// safe to run first and publish immediately.
    static func quickScan() -> QuickScan {
        let start = Date()
        var result = QuickScan()
        forEachService(matching: droboDextMatches()) { _ in result.driverBound = true }
        result.devices = scan()
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Open every bound enclosure in turn and read the lot. A record that fails
    /// is skipped rather than failing the enclosure: partial data still tells
    /// you more than an error page does.
    ///
    /// `skipping` is keyed by the *provider* registry ID — the SCSI nub — because
    /// that is the identity the quick scan already knows, which lets refusals
    /// remembered from a previous launch be applied on the very first read
    /// rather than being rediscovered every time.
    static func readAll(records wanted: [UInt8],
                        skipping: [UInt64: Set<UInt8>] = [:]) -> [EnclosureReading] {
        var out: [EnclosureReading] = []

        forEachService(matching: droboDextMatches()) { svc in
            var r = EnclosureReading()
            r.entryID = entryID(svc)
            r.driverBuild = regString(svc, "DroboBuild")
            r.personality = regString(svc, "DroboPersonality")

            // The nub directly above us carries the INQUIRY identity.
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS,
               parent != 0 {
                r.providerID = entryID(parent)
                let id = inquiryIdentity(parent)
                r.vendor = id.vendor
                r.product = id.product
                r.revision = id.revision
                IOObjectRelease(parent)
            }

            r.usbSerial = lookUp(from: svc) { entry in
                regString(entry, "USB Serial Number") ?? regString(entry, "Serial Number")
            }
            r.wholeDisk = wholeDiskName(below: svc)

            let started = Date()
            // Only optional records may ever be skipped. Capacity, slots,
            // status, settings and configuration are what the app is for, and
            // no amount of remembered failure justifies not asking for them —
            // a poisoned skip list must not be able to blank the window.
            let skip = (skipping[r.providerID] ?? []).filter {
                ESARecord(rawValue: $0)?.isOptional == true
            }
            r.refused = skip

            var conn = Connection()
            do {
                try conn.open(svc)
                for page in wanted where !skip.contains(page) {
                    let t0 = Date()
                    if let data = try? conn.read(record: page) {
                        r.records[page] = data
                        r.succeeded.insert(page)
                    } else {
                        r.failed.insert(page)
                    }
                    r.timings[page] = Date().timeIntervalSince(t0)
                }
                if r.records.isEmpty { r.error = "The enclosure did not answer any request." }
            } catch {
                r.error = error.localizedDescription
            }
            conn.close()
            r.duration = Date().timeIntervalSince(started)

            out.append(r)
        }

        return out.sorted { $0.entryID < $1.entryID }
    }

    /// Every Drobo the SCSI stack knows about. Matching on the vendor string
    /// alone is deliberate: an enclosure we cannot claim still has to show up,
    /// or the app would report "no Drobo" while one sits there plugged in.
    static func scan() -> [ScannedDevice] {
        var claimedProviders = Set<UInt64>()
        forEachService(matching: droboDextMatches()) { svc in
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS,
               parent != 0 {
                claimedProviders.insert(entryID(parent))
                IOObjectRelease(parent)
            }
        }

        var found: [ScannedDevice] = []
        forEachService(matching: [IOServiceMatching("IOSCSIPeripheralDeviceNub"),
                                  IOServiceMatching("IOSCSILogicalUnitNub")]) { svc in
            let id = inquiryIdentity(svc)
            guard DroboIdentity.isDrobo(vendor: id.vendor, product: id.product) else { return }
            let eid = entryID(svc)
            found.append(ScannedDevice(id: eid,
                                       vendor: id.vendor,
                                       product: id.product,
                                       revision: id.revision,
                                       claimed: claimedProviders.contains(eid)))
        }
        return found.sorted { $0.id < $1.id }
    }

    /// The nub carries the INQUIRY strings flat, but further down the stack the
    /// same information lives in a Device Characteristics dict. Handle both,
    /// exactly as droboprobe had to.
    private static func inquiryIdentity(_ entry: io_registry_entry_t)
    -> (vendor: String, product: String, revision: String) {
        var vendor = regString(entry, "Vendor Identification")
        var product = regString(entry, "Product Identification")
        var revision = regString(entry, "Product Revision Level")

        if vendor == nil || product == nil,
           let dc = property(entry, "Device Characteristics") as? [String: Any] {
            vendor = vendor ?? (dc["Vendor Name"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            product = product ?? (dc["Product Name"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            revision = revision ?? (dc["Product Revision Level"] as? String)?
                .trimmingCharacters(in: .whitespaces)
        }
        return (vendor ?? "", product ?? "", revision ?? "")
    }

    /// The BSD name of the whole disk under this driver, so the right mounted
    /// volume can be picked out when more than one enclosure is attached.
    private static func wholeDiskName(below service: io_service_t) -> String? {
        var whole: String?
        var anyPartition: String?

        lookDown(from: service) { child in
            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  let bsd = regString(child, "BSD Name") else { return true }
            if let isWhole = property(child, "Whole") as? Bool, isWhole {
                whole = bsd
                return false
            }
            if anyPartition == nil { anyPartition = bsd }
            return true
        }

        if let whole { return whole }
        // diskNsM -> diskN, for the case where the whole-disk node was missed.
        // Not firstIndex(of: "s"): that finds the one in "disk".
        guard let part = anyPartition,
              let range = part.range(of: "^disk[0-9]+", options: .regularExpression)
        else { return anyPartition }
        return String(part[range])
    }
}

// MARK: - Mounted volumes

struct VolumeInfo: Sendable, Equatable {
    var name: String
    var mountPoint: String
    var device: String
    var totalBytes: UInt64
    var freeBytes: UInt64
}

enum Volumes {

    /// Everything currently mounted, with the BSD device it came from. Matching
    /// on the device is what ties a volume to an enclosure; the old guess of
    /// "whichever volume claims to be much bigger than the array" cannot tell
    /// two Drobos apart.
    static func mounted() -> [VolumeInfo] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        return (0..<Int(count)).map { i in
            var fs = buffer[i]
            let device = withUnsafeBytes(of: &fs.f_mntfromname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let mountPoint = withUnsafeBytes(of: &fs.f_mntonname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let block = UInt64(fs.f_bsize)
            let url = URL(fileURLWithPath: mountPoint)
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName

            return VolumeInfo(name: name ?? url.lastPathComponent,
                              mountPoint: mountPoint,
                              device: device,
                              totalBytes: UInt64(fs.f_blocks) * block,
                              freeBytes: UInt64(fs.f_bavail) * block)
        }
    }

    /// The volume sitting on a given whole disk, if it is mounted at all.
    static func on(disk: String?, from volumes: [VolumeInfo]) -> VolumeInfo? {
        guard let disk, !disk.isEmpty else { return nil }
        return volumes.first {
            $0.device == "/dev/\(disk)" || $0.device.hasPrefix("/dev/\(disk)s")
        }
    }
}
