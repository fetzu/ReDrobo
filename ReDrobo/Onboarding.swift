//  Onboarding.swift
//
//  What it takes to get the driver loading, checked rather than described.
//
//  Most of these steps weaken macOS security, and none of them would be needed
//  if Apple had granted the DriverKit family entitlement to this team. The
//  assistant says so, shows what each step actually does, and hands over the
//  command instead of running it: they need root, they change how the whole Mac
//  boots, and that is not a decision an app should make on someone's behalf.

import SwiftUI
import Observation
import AppKit

// MARK: - Facts about this Mac

@Observable
@MainActor
final class SetupChecks {
    /// nil while unknown. True means the state ReDrobo needs.
    var sipDisabled: Bool?
    var developerMode: Bool?
    var amfiDisabled: Bool?
    var bootArgs: String?
    var checkedAt: Date?

    var inApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// A development build only gets its restricted entitlements honoured if a
    /// matching profile is embedded. Without one, AMFI has to be off instead.
    var hasProvisioningProfile: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/embedded.provisionprofile").path)
    }

    /// True when the entitlements can be honoured without touching AMFI.
    var entitlementsCanBeHonoured: Bool { hasProvisioningProfile || amfiDisabled == true }

    func refresh() async {
        let developer = Self.developerModeFromDatabase()
        let (sip, args) = await Task.detached(priority: .userInitiated) {
            (Self.sipIsDisabled(), Self.currentBootArgs())
        }.value
        sipDisabled = sip
        developerMode = developer
        bootArgs = args
        amfiDisabled = args.map { $0.contains("amfi_get_out_of_my_way") }
        checkedAt = Date()
    }

    // MARK: Gathering

    /// The same database systemextensionsctl reads, and it carries the developer
    /// mode flag, so this needs no subprocess at all.
    nonisolated private static func developerModeFromDatabase() -> Bool? {
        let url = URL(fileURLWithPath: "/Library/SystemExtensions/db.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization
                  .propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return root["developerMode"] as? Bool
    }

    nonisolated private static func sipIsDisabled() -> Bool? {
        guard let out = shell("/usr/bin/csrutil", ["status"]) else { return nil }
        let lower = out.lowercased()
        if lower.contains("disabled") { return true }
        if lower.contains("enabled")  { return false }
        return nil
    }

    nonisolated private static func currentBootArgs() -> String? {
        guard let out = shell("/usr/sbin/nvram", ["boot-args"]) else { return "" }
        // "boot-args\t<value>"
        return out.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }

    /// Read-only commands only, and a failure is an unknown rather than an error.
    nonisolated private static func shell(_ path: String, _ args: [String]) -> String? {
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
}

// MARK: - One step

struct SetupStep: Identifiable {
    enum State { case done, todo, blocked, unknown, optional }

    let id: String
    let title: String
    let detail: String
    var state: State
    var command: String? = nil
    var commandNote: String? = nil
    var buttonTitle: String? = nil
    var run: (() -> Void)? = nil

    var symbol: String {
        switch state {
        case .done:     return "checkmark.circle.fill"
        case .todo:     return "circle"
        case .blocked:  return "exclamationmark.circle.fill"
        case .unknown:  return "questionmark.circle"
        case .optional: return "circle.dashed"
        }
    }

    var tint: Color {
        switch state {
        case .done:    return .green
        case .blocked: return .orange
        default:       return .secondary
        }
    }
}

// MARK: - The assistant

struct SetupView: View {
    let model: DroboModel
    @State private var checks = SetupChecks()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Card {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, number: index + 1)
                        if step.id != steps.last?.id { Divider() }
                    }
                }

                if needsSecurityChanges { securityNote }

                Card(title: "Putting it back") {
                    Text("Undo the two boot-level changes when you are finished, or when "
                       + "Apple grants the entitlement and they stop being necessary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    CommandBlock(command: "sudo nvram -d boot-args")
                    CommandBlock(command: "csrutil enable",
                                 note: "From recoveryOS, the same way you turned it off.")
                    Text("The driver stops loading once either is restored, which is "
                       + "expected until the entitlement is granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task { await checks.refresh() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setting up ReDrobo")
                .font(.largeTitle.weight(.semibold))
            Text("ReDrobo talks to a Drobo through a driver extension, and macOS will "
               + "not load one that Apple has not blessed. Until that entitlement is "
               + "granted, the Mac has to be told to accept it — which is what these "
               + "steps do, and why they should be done on a spare Mac rather than the "
               + "one you rely on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Check Again") { Task { await checks.refresh() } }
                    .buttonStyle(.glass)
                if let at = checks.checkedAt {
                    Text("Checked \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var needsSecurityChanges: Bool {
        checks.sipDisabled != true || !checks.entitlementsCanBeHonoured
    }

    private var securityNote: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These steps lower this Mac's defences")
                        .font(.body.weight(.medium))
                    Text("Turning off System Integrity Protection and AMFI lets any "
                       + "unsigned code that gets root do things macOS would normally "
                       + "refuse. That is a real reduction in security for the whole "
                       + "machine, not just for ReDrobo, and it is why the project's own "
                       + "advice is to use a spare Mac. ReDrobo will not make these "
                       + "changes for you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: The checklist

    private var steps: [SetupStep] {
        var out: [SetupStep] = []

        out.append(SetupStep(
            id: "location",
            title: "Keep ReDrobo in the Applications folder",
            detail: "macOS refuses to activate a driver extension from an app anywhere "
                  + "else. ReDrobo is currently at \(Bundle.main.bundleURL.path).",
            state: checks.inApplications ? .done : .blocked))

        out.append(SetupStep(
            id: "sip",
            title: "Turn off System Integrity Protection",
            detail: sipDetail,
            state: checks.sipDisabled == nil ? .unknown
                 : (checks.sipDisabled! ? .done : .todo),
            command: "csrutil disable",
            commandNote: "Run this in recoveryOS, not here. Shut down, hold the power "
                       + "button until \"Loading startup options\" appears, then choose "
                       + "Options ▸ Utilities ▸ Terminal. Apple Silicon requires you to "
                       + "be physically at the machine; this cannot be done over screen "
                       + "sharing."))

        out.append(SetupStep(
            id: "developer",
            title: "Turn on driver extension developer mode",
            detail: "Lets macOS load a driver that has not been through the App Store. "
                  + "The command fails while SIP is on, which is a useful check that "
                  + "the previous step took.",
            state: checks.developerMode == nil ? .unknown
                 : (checks.developerMode! ? .done : .todo),
            command: "systemextensionsctl developer on"))

        if !checks.hasProvisioningProfile {
            out.append(SetupStep(
                id: "amfi",
                title: "Stop AMFI enforcing entitlements",
                detail: "ReDrobo carries restricted entitlements. On a development build "
                      + "those are only honoured with a matching provisioning profile "
                      + "embedded, and this copy has none — so AMFI has to be told to "
                      + "stand down instead, or the app is killed the moment it launches."
                      + (checks.bootArgs.map { $0.isEmpty ? "" : " boot-args is currently \"\($0)\"." } ?? ""),
                state: checks.amfiDisabled == nil ? .unknown
                     : (checks.amfiDisabled! ? .done : .todo),
                command: "sudo nvram boot-args=\"amfi_get_out_of_my_way=1\"",
                commandNote: "Then restart. If it does not stick, the security policy is "
                           + "Reduced rather than Permissive: go back to recoveryOS, open "
                           + "Startup Security Utility and choose Permissive Security."))
        } else {
            out.append(SetupStep(
                id: "profile",
                title: "Provisioning profile embedded",
                detail: "This build carries a profile, so its entitlements are honoured "
                      + "without touching AMFI.",
                state: .done))
        }

        out.append(SetupStep(
            id: "install",
            title: "Install the driver",
            detail: driverDetail,
            state: driverState,
            buttonTitle: model.driver.isUsable ? nil : "Install Driver",
            run: model.driver.isUsable ? nil : { model.installDriver() }))

        out.append(SetupStep(
            id: "approve",
            title: "Approve it in System Settings",
            detail: "macOS holds a new driver extension until you allow it, under "
                  + "General ▸ Login Items & Extensions ▸ Driver Extensions.",
            state: approvalState,
            buttonTitle: "Open System Settings",
            run: { DriverExtension.openExtensionSettings() }))

        out.append(SetupStep(
            id: "restart",
            title: "Restart the Mac",
            detail: restartDetail,
            state: restartState))

        return out
    }

    private var sipDetail: String {
        switch checks.sipDisabled {
        case true?:  return "Off, which is what a development driver needs."
        case false?: return "On. macOS will refuse to load ReDrobo's driver while it is."
        default:     return "Could not be read on this Mac."
        }
    }

    private var driverDetail: String {
        switch model.driver {
        case .installed(let build, true):
            return "Installed, build \(build ?? "?")."
        case .installed(let build, false):
            return "Build \(build ?? "?") is installed but switched off."
        case .awaitingApproval: return "Installed, waiting for you to approve it."
        case .notInstalled:     return "Not installed yet."
        case .checking:         return "Asking macOS…"
        case .error(let why):   return why
        }
    }

    private var driverState: SetupStep.State {
        switch model.driver {
        case .installed(_, true):  return .done
        case .installed(_, false): return .blocked
        case .awaitingApproval:    return .done
        case .checking:            return .unknown
        default:                   return .todo
        }
    }

    private var approvalState: SetupStep.State {
        switch model.driver {
        case .awaitingApproval:    return .todo
        case .installed(_, false): return .todo
        case .installed(_, true):  return .done
        default:                   return .optional
        }
    }

    private var restartDetail: String {
        if model.restartRequired {
            return "Build \(model.installedBuild ?? "?") is installed but build "
                 + "\(model.runningBuild ?? "?") is still running. macOS does not "
                 + "replace a driver until the Mac restarts."
        }
        if model.driverBound {
            return "The driver is running and bound to an enclosure. Nothing to do."
        }
        return "macOS keeps running the previous driver, or none at all, until the Mac "
             + "restarts. Do this after every install, every time."
    }

    private var restartState: SetupStep.State {
        if model.driverBound && !model.restartRequired { return .done }
        if model.restartRequired { return .todo }
        return model.driver.isUsable ? .todo : .optional
    }
}

// MARK: - Rows

private struct StepRow: View {
    let step: SetupStep
    let number: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.title3)
                .foregroundStyle(step.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(step.title)")
                    .font(.body.weight(.medium))
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = step.command, step.state != .done {
                    CommandBlock(command: command, note: step.commandNote)
                }

                if let title = step.buttonTitle, let run = step.run, step.state != .done {
                    Button(title, action: run)
                        .buttonStyle(.glass)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// A command to run in Terminal, with a copy button. Deliberately not a button
/// that runs it: these need root and change how the Mac boots.
struct CommandBlock: View {
    let command: String
    var note: String? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "document.on.document")
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}
