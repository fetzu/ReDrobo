//  Diagnostics.swift
//
//  A text dump meant to be pasted into a forum post or an issue.
//
//  Redaction is on by default and covers the things that identify a person
//  rather than a device: the enclosure's name, its serial number, and the name
//  and path of the mounted volume. Model numbers, capacities and firmware
//  stay, because those are the whole reason anyone would ask for this file.

import Foundation
import AppKit

enum Diagnostics {

    @MainActor
    static func report(model: DroboModel, redacted: Bool) async -> String {
        // Snapshot everything off the main actor first; the rest is string work.
        let enclosures = model.enclosures
        let scanned = model.scanned
        let driver = model.driver
        let carried = model.carriedBuild
        let running = model.runningBuild

        return await Task.detached(priority: .userInitiated) {
            build(enclosures: enclosures, scanned: scanned, driver: driver,
                  carried: carried, running: running, redacted: redacted)
        }.value
    }

    // MARK: Assembly

    private static func build(enclosures: [Enclosure],
                              scanned: [ScannedDevice],
                              driver: DriverInstallState,
                              carried: String?,
                              running: String?,
                              redacted: Bool) -> String {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }
        func heading(_ s: String) { line(); line("## \(s)"); line() }

        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        line("# ReDrobo diagnostics")
        line()
        line("Generated  \(ISO8601DateFormatter().string(from: Date()))")
        line("Redacted   \(redacted ? "yes, names and serials removed" : "NO, this contains identifying values")")
        if redacted {
            line("           Raw records are searched for every known name and serial,")
            line("           and bytes past a record's declared length are dropped.")
        }

        line()
        line("ReDrobo logs to the unified log. To pull the same period as this report:")
        line("  " + Log.showCommand)

        heading("Machine")
        line("macOS       \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("Hardware    \(sysctl("hw.model") ?? "unknown")")
        line("SIP         \(shell("/usr/bin/csrutil", ["status"]) ?? "unknown")")
        line("boot-args   \(shell("/usr/sbin/nvram", ["boot-args"]) ?? "(none set)")")

        heading("Driver")
        line("App           \(short) (\(build))")
        line("Carried dext  \(carried ?? "not found in the app bundle")")
        switch driver {
        case .checking:         line("Installed     still asking sysextd")
        case .notInstalled:     line("Installed     no")
        case .awaitingApproval: line("Installed     waiting for approval in System Settings")
        case .error(let why):   line("Installed     could not tell: \(why)")
        case .installed(let b, let enabled):
            line("Installed     \(b ?? "?") \(enabled ? "(enabled)" : "(present but not enabled)")")
        }
        line("Running       \(running ?? "no driver is bound to an enclosure")")
        if let running, let installedBuild = driver.installedBuild, running != installedBuild {
            line()
            line("NOTE: the running build differs from the installed one. macOS keeps")
            line("      executing the previous driver until the Mac is restarted.")
        }

        heading("Drobo devices the SCSI stack can see")
        if scanned.isEmpty {
            line("None. No enclosure is attached, or it did not enumerate as USB mass storage.")
        } else {
            line("Vendor Identification / Product Identification / Revision / claimed by ReDrobo")
            line()
            for d in scanned {
                line("  " + pad(d.vendor, 10) + pad(d.product, 18)
                     + pad(d.revision, 10) + (d.claimed ? "yes" : "NO"))
            }
            if scanned.contains(where: { !$0.claimed }) {
                line()
                line("An enclosure marked NO is attached but the driver did not take it.")
                line("Adding a personality with exactly the Vendor and Product strings above")
                line("to DroboDext/Info.plist is what makes it work; see the comment at the")
                line("top of that file.")
            }
        }

        for e in enclosures {
            heading("Enclosure: \(redacted ? redactedName(e) : e.displayName)")
            line("Model         \(e.modelName) rev \(e.revision)")
            line("Serial        \(redacted ? "(redacted)" : (e.serial ?? "unknown"))")
            line("Personality   \(e.personality ?? "unknown")")
            line("Driver build  \(e.driverBuild ?? "unknown")")
            line("Connected     \(e.isConnected ? "yes" : "no, last seen \(e.lastSeen)")")
            if let why = e.error { line("Error         \(why)") }

            if let s = e.snapshot {
                line()
                line("Capacity      total \(s.totalBytes)  used \(s.usedBytes)  free \(s.freeBytes)")
                line("              \(Fmt.tib(s.usedBytes)) used of \(Fmt.tib(s.totalBytes)), \(s.usedPercent)%")
                if s.unprotectedTotalBytes > 0 {
                    line("              unprotected total \(s.unprotectedTotalBytes)")
                }
                line("Thresholds    yellow \(s.yellowThresholdPercent)%, red \(s.redThresholdPercent)%")
                line("Firmware      \(s.firmwareVersion) build \(s.firmwareBuild), \(s.platform), built \(s.firmwareBuiltOn)")
                line("Protocol      \(s.protocolVersion)")
                line("Slots         \(s.slotCount), volumes \(s.lunCount) of max \(s.maxLuns)")
                if s.spinDownDelay > 0 { line("Spin down     \(s.spinDownDelay) minutes") }

                line()
                line("Protection")
                line("  protected now   \(s.isProtected ? "yes" : "NO -- status bit 6 is set")")
                line("  raw installed   \(s.rawInstalledBytes)")
                line("  held back       \(s.reservedForProtectionBytes)")
                line(String(format: "  usable share    %.0f%% of the disks",
                            s.usableFraction * 100))
                line("  level           \(s.redundancyLabel)")
                if let fit = s.redundancyFit {
                    line(String(format: "                  derived from the capacities, fits to %.1f%%",
                                abs(fit - 1) * 100))
                } else {
                    line("                  the capacities fit neither case closely enough to call")
                }

                line()
                line(String(format: "Status word   0x%08X   severity %@", s.statusWord,
                            (String(describing: s.severity)) as NSString))
                line("Relayouts     \(s.relayoutCount)")
                if s.diskPackStatus != 0 {
                    line(String(format: "Disk pack st  0x%08X", s.diskPackStatus))
                }
                for entry in DroboStatus.decompose(UInt64(s.statusWord)) {
                    line("  bit " + pad(String(entry.bit), 4)
                         + (entry.name ?? "not named in Drobo's own alert code"))
                }
                line(String(format: "Feature flags 0x%016llX", s.featureFlags))
                for f in FeatureState.named(in: s.featureFlags) {
                    line("  bit \(f.rawValue.trailingZeroBitCount)  \(f.label)")
                }
                let unexplained = FeatureState.unnamed(in: s.featureFlags)
                if !unexplained.isEmpty {
                    line("  set but unexplained: "
                         + unexplained.map(String.init).joined(separator: ", "))
                }

                if !s.systemInfoWords.isEmpty {
                    line()
                    line("System info 0x33 -- is one of these the firmware feature table?")
                    for c in s.featureTableCandidates {
                        line(String(format: "  word %d  0x%08X", c.index, c.value))
                        line("    " + c.verdict)
                        for crit in c.criteria {
                            line("    " + (crit.agrees ? "ok  " : "no  ") + crit.summary
                                 + (crit.decisive ? "" : "  [inferred]"))
                        }
                        if c.fits {
                            line("    would mean: "
                                 + c.features.map(\.label).joined(separator: ", "))
                            if !c.unnamedBits.isEmpty {
                                line("    plus unnamed bits: "
                                     + c.unnamedBits.map(String.init).joined(separator: ", "))
                            }
                        }
                    }
                }

                line()
                line("Drive bays" + (s.hasExtendedSlots
                     ? " (extended record 0x35 answered)"
                     : " (only the basic record 0x03; no health, serial or temperature)"))
                for bay in s.bays {
                    line("  " + pad(bay.label, 14)
                         + pad(String(bay.capacityBytes), 16, leading: true)
                         + "  " + (bay.isEmpty ? "empty" : bay.model))
                    guard bay.extended, !bay.isEmpty else { continue }
                    var detail = ["health \(bay.health.label)",
                                  "slot status \(bay.slotStatus)",
                                  "type \(bay.kind.label)",
                                  "errors \(bay.errorCount)"]
                    if let t = bay.temperatureC { detail.append("\(t) C") }
                    if let l = bay.lifeRemainingPercent { detail.append("life \(l)%") }
                    if !bay.firmwareRevision.isEmpty { detail.append("fw \(bay.firmwareRevision)") }
                    detail.append("serial " + (redacted ? "(redacted)" : bay.serial))
                    line("                " + detail.joined(separator: ", "))
                }
            }

            if let v = e.volume {
                line()
                line("Volume        \(redacted ? "(redacted)" : v.name) on \(redacted ? "(redacted)" : v.mountPoint)")
                line("              device \(v.device)")
                line("              macOS reports \(Fmt.tib(v.totalBytes)) total, \(Fmt.tib(v.freeBytes)) free")
                if let s = e.snapshot, v.freeBytes > s.freeBytes {
                    line("              overstated by \(Fmt.tib(v.freeBytes - s.freeBytes))")
                }
            }

            if let s = e.snapshot, !s.raw.isEmpty {
                line()
                line("Raw records (valid portion only; bytes past the declared length are")
                line("stale buffer contents, not part of the record)")
                let masked = secrets(in: enclosures)
                for record in ESARecord.allCases {
                    guard let data = s.raw[record.rawValue] else { continue }
                    let bytes = redacted
                        ? redact(record: record, data, secrets: masked)
                        : data
                    line()
                    line(String(format: "  0x%02X ", record.rawValue) + record.label)
                    line(Hex.dump(bytes,
                                  limit: Redaction.printableLength(data, redacted: redacted),
                                  indent: "    "))
                }
            }
        }

        return out
    }

    // MARK: Redaction

    private static func redactedName(_ e: Enclosure) -> String {
        e.snapshot?.name.isEmpty == false ? "(name redacted)" : e.modelName
    }

    /// Everything worth hiding, gathered from what was decoded, so it can be
    /// hunted for by content rather than only by offset.
    private static func secrets(in enclosures: [Enclosure]) -> [Data] {
        var strings: Set<String> = []
        for e in enclosures {
            if let serial = e.serial { strings.insert(serial) }
            if let volume = e.volume {
                strings.insert(volume.name)
                strings.insert(volume.mountPoint)
            }
            guard let s = e.snapshot else { continue }
            strings.insert(s.name)
            strings.insert(s.serial)
            for bay in s.bays { strings.insert(bay.serial) }
        }
        return Redaction.secrets(from: Array(strings))
    }

    /// Names and serials sit in cleartext inside the records themselves, so a
    /// "redacted" dump that printed the raw bytes would hand back exactly what
    /// the header just removed.
    ///
    /// Blanking the fields ReDrobo decodes is not enough, and a real capture
    /// proved it: the enclosure name turned up inside FirmwareInfo, and five
    /// disk serials inside the stale tails of Options and Options2, none of
    /// which are fields this app parses. So the bytes are searched for every
    /// known value as well.
    private static func redact(record: ESARecord, _ data: Data,
                               secrets: [Data]) -> Data {
        var copy = data
        func blank(_ offset: Int, _ length: Int) {
            let start = copy.startIndex + offset
            let end = min(start + length, copy.endIndex)
            guard start < end else { return }
            copy.replaceSubrange(start..<end, with: Data(repeating: 0, count: end - start))
        }

        switch record {
        case .system:
            blank(10, 32)                       // enclosure name
        case .deviceSerial:
            blank(4, 24)                        // enclosure serial
        case .diskPack:
            // Not decoded, so nothing is known to be safe.
            blank(4, copy.count - 4)
        case .slots2:
            let slots = Int(copy.u8(8))
            for i in 0..<max(0, slots) { blank(12 + i * 108 + 68, 24) }
        default:
            break
        }

        return Redaction.scrub(copy, removing: secrets)
    }


    // MARK: Formatting

    /// Foundation does not honour a width on %@ dependably, so columns are
    /// padded here rather than in a format string.
    private static func pad(_ s: String, _ width: Int, leading: Bool = false) -> String {
        guard s.count < width else { return s + (leading ? "" : " ") }
        let fill = String(repeating: " ", count: width - s.count)
        return leading ? fill + s : s + fill
    }


    // MARK: Asking the system

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Read-only commands only, and a failure is just an unknown line in the
    /// report rather than anything to handle.
    private static func shell(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: Getting it out of the app

    @MainActor
    static func save(_ text: String, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
