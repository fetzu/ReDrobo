//  Enclosure.swift
//
//  One attached enclosure, as the UI sees it.
//
//  Deliberately free of the model, Observation and AppKit, so the offline
//  checks can exercise it. What it mostly encodes is the difference between
//  "not read yet" and "this firmware does not have it", which is the whole
//  reason the window can be honest about a read still being in progress.

import Foundation

struct Enclosure: Identifiable, Sendable {
    let id: String
    var displayName: String
    var vendor = ""
    var product = ""
    var revision = ""
    var serial: String?

    /// The build of the driver actually running for this enclosure, read back
    /// from the matched personality. Not the same thing as the build that is
    /// installed, until the Mac has been restarted.
    var driverBuild: String?
    var personality: String?

    var wholeDisk: String?
    var volume: VolumeInfo?
    var snapshot: DroboSnapshot?
    var error: String?

    var isConnected = true
    var lastSeen = Date()

    /// Sub-pages this enclosure will not answer. Kept so the UI can tell
    /// "not read yet" from "this firmware does not have it" — showing a blank
    /// for both is how the window came to look finished while it was still
    /// halfway through reading.
    var refused: Set<UInt8> = []

    /// True between the first pass finishing and the second one completing,
    /// which is the only window in which a missing record is genuinely still
    /// on its way.
    var readInProgress = false

    /// Where a record's worth of the display currently stands.
    enum RecordState {
        case present
        /// A read is actually running and this record has not arrived yet.
        case reading
        /// The read finished and this record was not among the answers. Not the
        /// same as refused: one silence is not proof of absence.
        case noAnswer
        /// Failed enough times in a row to be believed absent, and no longer
        /// asked for.
        case unavailable
    }

    func state(of record: ESARecord) -> RecordState {
        if snapshot?.has(record) == true { return .present }
        if refused.contains(record.rawValue) { return .unavailable }
        // Once the read is over, nothing is "still reading". Saying otherwise is
        // what left the progress card up for the fifteen minutes it took a
        // record to fail three times and be written off.
        return readInProgress ? .reading : .noAnswer
    }

    /// True only while a read is actually running with something outstanding.
    var isStillReading: Bool {
        readInProgress && ESARecord.allCases.contains { state(of: $0) == .reading }
    }

    var modelName: String {
        let parts = [vendor, product].filter { !$0.isEmpty }
        return parts.isEmpty ? "Drobo" : parts.joined(separator: " ")
    }

    var summaryLine: String {
        guard let s = snapshot, s.totalBytes > 0 else { return modelName }
        return "\(s.usedPercent)% used · \(Fmt.tib(s.freeBytes)) free of \(Fmt.tib(s.totalBytes))"
    }

    var health: DroboSnapshot.Health { snapshot?.health ?? .unknown }

    /// A disk the enclosure itself has marked warning or failed. Only ever
    /// true when the extended slot record answered, so a firmware that does
    /// not report disk health never claims everything is fine.
    var failingDisks: [DriveBay] {
        snapshot?.bays.filter(\.needsAttention) ?? []
    }

    var hasFailingDisk: Bool { !failingDisks.isEmpty }
}

