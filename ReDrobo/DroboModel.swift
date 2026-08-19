//  DroboModel.swift
//
//  The polling model the whole UI observes. One enclosure is Enclosure.swift. It owns the list of enclosures
//  rather than a single one, and it keeps "what is installed", "what is
//  plugged in" and "what answered" as three separate facts, because collapsing
//  them is what made an unplugged Drobo look like a missing driver.

import Foundation
import Observation

// MARK: - One poll's worth of work

private struct RefreshResult: Sendable {
    var readings: [EnclosureReading]
    var scanned: [ScannedDevice]
    var volumes: [VolumeInfo]
}

// MARK: - The model

@MainActor
@Observable
final class DroboModel {

    /// What the app should be showing. Every case is a different sentence to
    /// put in front of someone, which is the whole point of splitting them.
    enum Situation: Equatable {
        case checking
        case reading
        case ready
        case driverMissing
        case driverAwaitingApproval
        case driverDisabled
        case driverError(String)
        case noEnclosure
        case unclaimed([ScannedDevice])
        case silent(String)
    }

    /// One model, shared by the window, the menu bar and Settings. They are
    /// three views of the same polling loop, and the loop has to keep running
    /// with no window open at all.
    static let shared = DroboModel()

    var enclosures: [Enclosure] = []
    var selectedID: Enclosure.ID?
    var driver: DriverInstallState = .checking
    var scanned: [ScannedDevice] = []

    var isRefreshing = false
    var isInstalling = false
    var installMessage: String?
    var lastRefresh: Date?
    var recentEvents: [DroboEvent] = []

    /// True as soon as a DroboDext service exists in the registry. That is an
    /// instant lookup and it proves the driver is both installed and enabled,
    /// so the UI never has to wait on sysextd to say something useful.
    var driverBound = false

    /// What the last poll cost, split by phase. Surfaced in Settings because
    /// "how expensive is this" is a fair question and the honest answer is
    /// whatever this machine measures.
    var lastQuickScanSeconds: TimeInterval = 0
    var lastReadSeconds: TimeInterval = 0
    var lastRecordCount = 0
    var lastSlowestRecord: (page: UInt8, seconds: TimeInterval)?

    private var pollTask: Task<Void, Never>?
    private let watcher = DroboWatcher()
    private var previous: [String: Enclosure] = [:]
    /// Sub-pages each enclosure has already refused, so they are asked once.
    private var refused: [UInt64: Set<UInt8>] = [:]
    /// Consecutive failures per model per record. A record is only believed
    /// absent after failing repeatedly; a single bad read is a hiccup, and
    /// treating it as permanent is what once blanked the whole window.
    private var failureStreak: [String: [UInt8: Int]] = [:]
    private var lastDriverQuery: Date?
    /// True once a read pass has finished since the driver last became bound.
    private var hasReadOnce = false
    /// Records already read, per enclosure, so a poll only asks for what it
    /// actually needs and the snapshot is decoded from the union.
    private var recordCache: [UInt64: [UInt8: Data]] = [:]
    private var durableReadAt: [UInt64: Date] = [:]

    // MARK: Derived

    var selected: Enclosure? {
        enclosures.first { $0.id == selectedID } ?? enclosures.first
    }

    var connected: [Enclosure] { enclosures.filter(\.isConnected) }

    var situation: Situation {
        if connected.contains(where: { $0.snapshot != nil }) { return .ready }

        let unclaimed = scanned.filter { !$0.claimed }

        // A bound service settles the driver question on its own, and settles it
        // immediately. Waiting on sysextd here is what made the window sit on
        // "Checking…" for twenty seconds when nothing was wrong.
        if driverBound || driver.isUsable {
            if !unclaimed.isEmpty { return .unclaimed(unclaimed) }
            if scanned.isEmpty { return .noEnclosure }
            // Publishing the scan before the reads is what makes the window
            // responsive, but it also means there is a window where an
            // enclosure is known to be there and has simply not been read yet.
            // Saying "did not answer" then is a lie, and it was on screen for
            // as long as the first read took.
            if !hasReadOnce || isRefreshing { return .reading }
            return .silent(connected.compactMap(\.error).first
                           ?? "The enclosure did not answer.")
        }

        switch driver {
        case .checking:         return .checking
        case .notInstalled:     return .driverMissing
        case .awaitingApproval: return .driverAwaitingApproval
        case .error(let why):   return .driverError(why)
        case .installed(_, let enabled):
            guard enabled else { return .driverDisabled }
            if !unclaimed.isEmpty { return .unclaimed(unclaimed) }
            if scanned.isEmpty { return .noEnclosure }
            return .silent(connected.compactMap(\.error).first
                           ?? "The enclosure did not answer.")
        }
    }

    /// Whether the window should be showing the setup assistant rather than a
    /// one-line explanation. These are the states where there are actual steps
    /// to walk through.
    var needsSetup: Bool {
        switch situation {
        case .driverMissing, .driverDisabled, .driverAwaitingApproval: return true
        default: return false
        }
    }

    /// The driver this app carries against the one sysextd has. Different means
    /// pressing Install would actually change something.
    var carriedBuild: String? { DriverExtension.carriedBuild }
    var installedBuild: String? { driver.installedBuild }
    var runningBuild: String? { connected.compactMap(\.driverBuild).first }

    var installWouldUpgrade: Bool {
        guard let carried = carriedBuild, let installed = installedBuild else { return false }
        return carried != installed
    }

    /// Installed but not yet live. This is the reboot trap, made visible rather
    /// than left to be rediscovered from the log.
    var restartRequired: Bool {
        guard let running = runningBuild, let installed = installedBuild else { return false }
        return running != installed
    }

    // MARK: Polling

    private var bootstrapped = false

    /// Called once at launch, from the app delegate.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Log.info("ReDrobo starting, carried driver build \(DriverExtension.carriedBuild ?? "?")")
        Prefs.shared.applyActivationPolicy()
        Notifier.shared.prepare()
        start()
    }

    func start() {
        guard pollTask == nil else { return }
        checkDriver()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = Prefs.shared.pollSeconds
                try? await Task.sleep(for: .seconds(max(5, seconds)))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() { Task { await refresh() } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Phase one is registry only: no user client, no CDB, microseconds. It
        // is published straight away so the window can say "no Drobo connected"
        // without waiting on anything.
        let quick = await Task.detached(priority: .userInitiated) {
            DroboIOKit.quickScan()
        }.value
        if driverBound != quick.driverBound {
            Log.info("driver \(quick.driverBound ? "bound to an enclosure" : "no longer bound")")
        }
        driverBound = quick.driverBound
        scanned = quick.devices
        lastQuickScanSeconds = quick.duration
        Log.debug("scan: \(quick.devices.count) Drobo device(s), bound=\(quick.driverBound), "
                + "\(Int(quick.duration * 1000)) ms")

        guard quick.driverBound else {
            hasReadOnce = false
            recordCache.removeAll()
            merge(RefreshResult(readings: [], scanned: quick.devices, volumes: []),
                  readComplete: true)
            lastRefresh = Date()
            lastReadSeconds = 0
            lastRecordCount = 0
            checkDriverIfStale()
            return
        }

        // Refusals are remembered across launches per model, so a firmware that
        // does not answer a record is asked once ever rather than once a launch.
        var skip: [UInt64: Set<UInt8>] = [:]
        for device in quick.devices {
            skip[device.id] = refused[device.id] ?? Refusals.load(model: device.modelKey)
        }

        // Phase two, the SCSI traffic, in two passes: enough for a real screen
        // first, then everything else. Thirteen sequential round trips before
        // showing anything is what made launch feel broken.
        var readSeconds: TimeInterval = 0
        var recordsRead = 0
        var slowest: (page: UInt8, seconds: TimeInterval)?

        // Once per refresh, not once per pass: getmntinfo plus a resource-value
        // lookup for every mounted volume, to answer a question whose answer
        // cannot change in the second or two between the two passes.
        let volumes = await Task.detached(priority: .utility) { Volumes.mounted() }.value

        for pass in 0..<2 {
            let pages = pass == 0 ? ESARecord.pages(in: .essential)
                                  : duePagesForSecondPass()
            guard !pages.isEmpty else { continue }

            let currentSkip = skip
            let readings = await Task.detached(priority: .utility) {
                DroboIOKit.readAll(records: pages, skipping: currentSkip)
            }.value

            for reading in readings {
                var known = refused[reading.providerID] ?? reading.refused
                let model = reading.modelKey

                // Anything that answered is present, whatever was believed
                // before. This is what lets the app recover on its own.
                for page in reading.succeeded {
                    failureStreak[model, default: [:]][page] = 0
                    if known.remove(page) != nil {
                        Log.info(String(format: "record 0x%02X answered again, "
                                      + "no longer skipping it", page))
                    }
                }

                for page in reading.failed {
                    guard ESARecord(rawValue: page)?.isOptional == true else {
                        // Required records are retried for ever. If capacity or
                        // status cannot be read that is a fault to report, not
                        // a reason to stop asking.
                        Log.warning(String(format: "record 0x%02X failed and is "
                                         + "required, will keep asking", page))
                        continue
                    }
                    let streak = (failureStreak[model]?[page] ?? 0) + 1
                    failureStreak[model, default: [:]][page] = streak
                    if streak >= Refusals.failuresBeforeRefusing,
                       known.insert(page).inserted {
                        Log.warning(String(format: "%@ refused record 0x%02X "
                                         + "after %d attempts", model, page, streak))
                    }
                }

                Log.debug("read pass \(pass): \(reading.records.count) records in "
                        + "\(Int(reading.duration * 1000)) ms from \(model)")
                refused[reading.providerID] = known
                Refusals.save(model: model, pages: known)
                skip[reading.providerID] = known
                recordCache[reading.entryID, default: [:]].merge(reading.records) { _, new in new }
                if pass == 1 { durableReadAt[reading.entryID] = Date() }
                readSeconds += reading.duration
                recordsRead += reading.records.count
                if let s = reading.slowestRecord,
                   s.seconds > (slowest?.seconds ?? 0) { slowest = s }
            }

            merge(RefreshResult(readings: readings, scanned: quick.devices, volumes: volumes),
                  readComplete: pass == 1)
            if pass == 0 { hasReadOnce = true }
        }

        lastReadSeconds = readSeconds
        lastRecordCount = recordsRead
        lastSlowestRecord = slowest
        lastRefresh = Date()
    }

    /// Volatile records every time; durable ones only when they have gone stale.
    private func duePagesForSecondPass() -> [UInt8] {
        var pages = ESARecord.pages(in: .volatile)
        let stale = durableReadAt.isEmpty || durableReadAt.values.contains {
            Date().timeIntervalSince($0) > ESARecord.durableLifetime
        }
        if stale { pages += ESARecord.pages(in: .durable) }
        return pages
    }

    // MARK: Driver

    /// Throw away everything remembered about which records an enclosure will
    /// not answer, and ask for all of them again on the next poll.
    func forgetSkippedRecords() {
        Refusals.reset()
        refused.removeAll()
        failureStreak.removeAll()
        Log.info("cleared the remembered list of unanswered records")
        refreshNow()
    }

    func checkDriver() {
        lastDriverQuery = Date()
        // Answer from the on-disk database first so the UI never waits, then
        // let the authoritative request correct it a moment later.
        if driver == .checking, let cached = DriverExtension.cachedStatus() {
            driver = cached
        }
        DriverExtension.status { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if self.driver != state {
                    Log.info("driver state: \(String(describing: state))")
                }
                self.driver = state
            }
        }
    }

    /// sysextd is not always quick, and asking it every thirty seconds when the
    /// answer has not changed is pure latency. Once a minute is plenty.
    private func checkDriverIfStale() {
        guard let last = lastDriverQuery else { return checkDriver() }
        if Date().timeIntervalSince(last) > 60 { checkDriver() }
    }

    func uninstallDriver() {
        isInstalling = true
        DriverExtension.deactivate { [weak self] text, finished in
            Task { @MainActor in
                guard let self else { return }
                self.installMessage = text
                if finished {
                    self.isInstalling = false
                    self.checkDriver()
                    await self.refresh()
                }
            }
        }
    }

    func installDriver() {
        isInstalling = true
        DriverExtension.activate { [weak self] text, finished in
            Task { @MainActor in
                guard let self else { return }
                self.installMessage = text
                if finished {
                    self.isInstalling = false
                    self.checkDriver()
                    await self.refresh()
                }
            }
        }
    }

    // MARK: Merging

    private func merge(_ result: RefreshResult, readComplete: Bool) {
        scanned = result.scanned

        var next: [Enclosure] = []
        var used = Set<String>()

        for r in result.readings {
            // Everything read so far for this enclosure, not just this pass, so
            // a durable record read once keeps showing until it is re-read.
            let records = recordCache[r.entryID] ?? r.records
            let snapshot = records.isEmpty ? nil : DroboSnapshot.decode(records)
            let name = snapshot?.name ?? ""

            var id = Self.identity(r, name: name)
            // Two nameless enclosures of the same model would otherwise collide.
            if !used.insert(id).inserted {
                id = "reg:\(r.providerID)"
                used.insert(id)
            }

            var e = Enclosure(id: id,
                              displayName: name.isEmpty ? Self.fallbackName(r) : name)
            e.vendor = r.vendor
            e.product = r.product
            e.revision = r.revision
            e.serial = r.usbSerial
            e.driverBuild = r.driverBuild
            e.personality = r.personality
            e.wholeDisk = r.wholeDisk
            e.volume = Volumes.on(disk: r.wholeDisk, from: result.volumes)
            e.snapshot = snapshot
            e.refused = refused[r.providerID] ?? r.refused
            e.readInProgress = !readComplete
            e.error = r.error
            e.isConnected = true
            e.lastSeen = Date()
            next.append(e)
        }

        // An enclosure that has gone stays visible, greyed and dated, rather
        // than the window emptying out with no explanation.
        let live = Set(next.map(\.id))
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for (id, old) in previous where !live.contains(id) && old.lastSeen > cutoff {
            var gone = old
            gone.isConnected = false
            next.append(gone)
        }

        next.sort {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        let events = watcher.events(previous: previous, current: next)
        for event in events { Log.info("event: \(event.title) — \(event.body)") }
        if !events.isEmpty {
            Notifier.shared.post(events)
            recentEvents = (events + recentEvents).prefix(30).map { $0 }
        }

        enclosures = next
        previous = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if selectedID == nil || !live.contains(selectedID!) {
            selectedID = next.first(where: \.isConnected)?.id ?? next.first?.id
        }
    }

    /// Serial first, because it survives a replug into another port. Then the
    /// enclosure's own name, which is what someone would call it anyway. The
    /// registry ID is the last resort and only lasts as long as the connection.
    private static func identity(_ r: EnclosureReading, name: String) -> String {
        if let serial = r.usbSerial, !serial.isEmpty { return "usb:\(serial)" }
        if !name.isEmpty { return "name:\(name)" }
        return "reg:\(r.providerID)"
    }

    private static func fallbackName(_ r: EnclosureReading) -> String {
        let parts = [r.vendor, r.product].filter { !$0.isEmpty }
        return parts.isEmpty ? "Drobo" : parts.joined(separator: " ")
    }
}
