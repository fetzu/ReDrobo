//  Notifier.swift
//
//  Notifications, and the bookkeeping that stops them being noise.
//
//  Everything here fires on a *transition*. An array that is 90% full is not
//  news every thirty seconds; crossing 85% once is. The levels that have
//  already been announced are persisted, so restarting the app does not
//  re-announce a condition that has not changed.

import Foundation
import UserNotifications

// MARK: - Events

struct DroboEvent: Identifiable, Sendable {
    enum Kind: String, Sendable { case connection, capacity, bay, health }

    let id = UUID()
    let kind: Kind
    let enclosure: String
    let title: String
    let body: String
    let at = Date()
}

// MARK: - What has already been said

private struct WatchState: Codable {
    var level: [String: String] = [:]
    var bays: [String: String] = [:]
    var relayout: [String: UInt32] = [:]
    var status: [String: UInt32] = [:]
    /// Keyed "<enclosure>#<slot>", because a disk's health belongs to the slot
    /// it is in, and moving a disk between bays should read as a change.
    var diskHealth: [String: Int] = [:]
}

// MARK: - Working out what changed

@MainActor
final class DroboWatcher {
    private static let key = "watchState"
    private var state: WatchState

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(WatchState.self, from: data) {
            state = decoded
        } else {
            state = WatchState()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Compare one poll against the last and say what is worth telling someone.
    func events(previous: [String: Enclosure], current: [Enclosure]) -> [DroboEvent] {
        let prefs = Prefs.shared
        var events: [DroboEvent] = []
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        // Appearing and vanishing.
        if prefs.notifyConnection {
            for e in current where e.isConnected && previous[e.id]?.isConnected != true {
                events.append(DroboEvent(kind: .connection, enclosure: e.displayName,
                                         title: "\(e.displayName) connected",
                                         body: e.summaryLine))
            }
            for (id, old) in previous where old.isConnected
                                         && currentByID[id]?.isConnected != true {
                events.append(DroboEvent(kind: .connection, enclosure: old.displayName,
                                         title: "\(old.displayName) disconnected",
                                         body: "ReDrobo can no longer see this enclosure."))
            }
        }

        for e in current {
            guard e.isConnected, let now = e.snapshot else { continue }
            let name = e.displayName

            // --- capacity, against the enclosure's own threshold ------------
            let level = Self.level(of: now)
            let previousLevel = state.level[e.id]
            state.level[e.id] = level.rawValue

            if let previousLevel, previousLevel != level.rawValue, prefs.notifyCapacity {
                switch level {
                case .critical:
                    events.append(DroboEvent(kind: .capacity, enclosure: name,
                        title: "\(name) is nearly full",
                        body: "\(now.usedPercent)% used, \(Fmt.tib(now.freeBytes)) free."))
                case .warning:
                    let was = WatchLevel(rawValue: previousLevel) ?? .ok
                    events.append(DroboEvent(kind: .capacity, enclosure: name,
                        title: was == .critical ? "\(name) is no longer critical"
                                                : "\(name) is filling up",
                        body: "\(now.usedPercent)% used, past the enclosure's "
                            + "\(now.yellowThresholdPercent)% threshold. "
                            + "\(Fmt.tib(now.freeBytes)) free."))
                case .ok:
                    events.append(DroboEvent(kind: .capacity, enclosure: name,
                        title: "\(name) has room again",
                        body: "\(now.usedPercent)% used, \(Fmt.tib(now.freeBytes)) free."))
                }
            }

            // --- drive bays --------------------------------------------------
            let fingerprint = Self.fingerprint(of: now)
            let previousFingerprint = state.bays[e.id]
            state.bays[e.id] = fingerprint

            if let previousFingerprint, previousFingerprint != fingerprint, prefs.notifyBays {
                let changes = Self.describeBayChanges(from: previousFingerprint, to: fingerprint)
                events.append(DroboEvent(kind: .bay, enclosure: name,
                    title: "Drive bays changed on \(name)",
                    body: changes.isEmpty ? "The bay layout is not what it was."
                                          : changes.joined(separator: "\n")))
            }

            // --- rebuild and health -------------------------------------------
            let previousRelayout = state.relayout[e.id]
            state.relayout[e.id] = now.relayoutCount
            if let previousRelayout, previousRelayout != now.relayoutCount, prefs.notifyHealth {
                if now.relayoutCount > 0 && previousRelayout == 0 {
                    events.append(DroboEvent(kind: .health, enclosure: name,
                        title: "\(name) is rebuilding",
                        body: "The array has started a relayout. Leave it powered on."))
                } else if now.relayoutCount == 0 {
                    events.append(DroboEvent(kind: .health, enclosure: name,
                        title: "\(name) has finished rebuilding",
                        body: "The relayout count is back to zero."))
                }
            }

            // --- individual disks --------------------------------------------
            // Only meaningful when the extended slot record answered. A
            // firmware that does not report disk health must not be allowed to
            // look like an array where every disk is fine.
            if now.hasExtendedSlots {
                for bay in now.bays where !bay.isEmpty {
                    let key = "\(e.id)#\(bay.id)"
                    let previous = state.diskHealth[key]
                    state.diskHealth[key] = bay.health.rawValue
                    guard let previous, previous != bay.health.rawValue,
                          prefs.notifyDiskHealth else { continue }

                    let was = DiskHealth(rawValue: previous) ?? .good
                    if bay.health.isTrouble {
                        events.append(DroboEvent(kind: .bay, enclosure: name,
                            title: "\(bay.label) on \(name) is \(bay.health.label.lowercased())",
                            body: "\(bay.model)"
                                + (bay.serial.isEmpty ? "" : ", serial \(bay.serial)")
                                + ". The enclosure reported it as \(was.label.lowercased()) "
                                + "before. Make sure your backup is current."))
                    } else if was.isTrouble {
                        events.append(DroboEvent(kind: .bay, enclosure: name,
                            title: "\(bay.label) on \(name) is back to \(bay.health.label.lowercased())",
                            body: "\(bay.model) is no longer being reported as "
                                + "\(was.label.lowercased())."))
                    }
                }
            }

            let previousStatus = state.status[e.id]
            state.status[e.id] = now.statusWord
            if let previousStatus, previousStatus != now.statusWord, prefs.notifyHealth {
                let gained = DroboStatus.named(UInt64(now.statusWord) & ~UInt64(previousStatus))
                let cleared = DroboStatus.named(UInt64(previousStatus) & ~UInt64(now.statusWord))
                var lines: [String] = []
                if !gained.isEmpty {
                    lines.append("Now: " + gained.map(\.name).joined(separator: ", "))
                }
                if !cleared.isEmpty {
                    lines.append("Cleared: " + cleared.map(\.name).joined(separator: ", "))
                }
                if lines.isEmpty {
                    lines.append(String(format: "The status word moved from 0x%08X to 0x%08X, "
                                      + "and none of the bits that changed appear in Drobo's "
                                      + "own alert code.", previousStatus, now.statusWord))
                }
                events.append(DroboEvent(kind: .health, enclosure: name,
                    title: "\(name) changed status", body: lines.joined(separator: "\n")))
            }
        }

        save()
        return events
    }

    // MARK: Helpers

    private enum WatchLevel: String { case ok, warning, critical }

    private static func level(of s: DroboSnapshot) -> WatchLevel {
        if s.usedPercent >= 95 { return .critical }
        if s.yellowThresholdPercent > 0 && s.usedPercent >= s.yellowThresholdPercent {
            return .warning
        }
        return .ok
    }

    /// One line per slot, so a diff can name the bay that changed rather than
    /// just saying something did.
    private static func fingerprint(of s: DroboSnapshot) -> String {
        s.bays.map { "\($0.id)|\($0.capacityBytes)|\($0.model)" }.joined(separator: ";")
    }

    private static func describeBayChanges(from old: String, to new: String) -> [String] {
        func parse(_ s: String) -> [Int: (UInt64, String)] {
            var out: [Int: (UInt64, String)] = [:]
            for entry in s.split(separator: ";") {
                let parts = entry.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let slot = Int(parts[0]),
                      let capacity = UInt64(parts[1]) else { continue }
                out[slot] = (capacity, String(parts[2]))
            }
            return out
        }
        let before = parse(old), after = parse(new)
        var lines: [String] = []
        for slot in Set(before.keys).union(after.keys).sorted() {
            let b = before[slot], a = after[slot]
            guard b?.0 != a?.0 || b?.1 != a?.1 else { continue }
            let name = "Bay \(slot + 1)"
            switch (b?.0 ?? 0, a?.0 ?? 0) {
            case (0, let capacity) where capacity > 0:
                lines.append("\(name): drive inserted, \(a?.1 ?? "unknown")")
            case (_, 0):
                lines.append("\(name): drive removed")
            default:
                lines.append("\(name): now \(a?.1 ?? "unknown")")
            }
        }
        return lines
    }
}

// MARK: - Posting

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var authorized = false

    /// Asked for once, at launch. A refusal is not an error worth surfacing:
    /// the app works perfectly well without notifications and says so in
    /// Settings rather than nagging.
    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func post(_ events: [DroboEvent]) {
        guard Prefs.shared.notificationsEnabled, authorized else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = event.kind == .capacity || event.kind == .health ? .default : nil

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: event.id.uuidString,
                                      content: content, trigger: nil))
        }
    }

    /// Show them even when ReDrobo is the front app. The window may well be
    /// open on a different pane from the one that changed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
