//  SettingsView.swift
//
//  Preferences, plus the one place that tells you the whole truth about the
//  driver: what the app carries, what is installed, and what is actually
//  running. Those three differ more often than you would like, and every time
//  they do the answer is "restart the Mac".

import SwiftUI

struct SettingsView: View {
    let model: DroboModel
    @Bindable private var prefs = Prefs.shared
    @State private var confirmingRemoval = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            driver.tabItem { Label("Driver", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 500)
        .scenePadding()
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Application") {
                Picker("Show in the Dock", selection: $prefs.dockVisibility) {
                    ForEach(DockVisibility.allCases) { Text($0.label).tag($0) }
                }
                Text(prefs.dockVisibility.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Open at login", isOn: $prefs.openAtLogin)
                if let error = prefs.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Units") {
                Picker("Capacity", selection: $prefs.capacityUnits) {
                    ForEach(CapacityUnits.allCases) { Text($0.label).tag($0) }
                }
                Text("Dashboard printed TiB and wrote TB, so a 5.42 TB array is really "
                   + "5.42 TiB. Matching that keeps ReDrobo's numbers the same as the "
                   + "ones you are used to; the other option is simply honest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Temperature", selection: $prefs.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updating") {
                Picker("Check every", selection: $prefs.pollSeconds) {
                    ForEach(Prefs.pollChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minutes")
                            .tag(seconds)
                    }
                }
                Text("Each check is a short run of MODE SENSE reads. The volume stays "
                   + "mounted and nothing is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What the last check cost") {
                LabeledContent("Looking around", value: ms(model.lastQuickScanSeconds))
                LabeledContent("Reading records", value: ms(model.lastReadSeconds))
                LabeledContent("Records read", value: "\(model.lastRecordCount)")
                if let slowest = model.lastSlowestRecord {
                    LabeledContent("Slowest record",
                        value: String(format: "0x%02X, %@", slowest.page,
                                      ms(slowest.seconds) as NSString))
                }
                Text("Looking around is registry only and sends nothing to the "
                   + "enclosure. Reading is the actual cost: one MODE SENSE(10) per "
                   + "record, at most 1308 bytes each, answered by the controller "
                   + "rather than the disks. A record the enclosure refuses is asked "
                   + "for once and then left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Menu bar

    private var menuBar: some View {
        Form {
            Section {
                Toggle("Show ReDrobo in the menu bar", isOn: $prefs.showMenuBar)
            }

            Section("How much it says") {
                Picker("Show", selection: $prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Text(prefs.menuBarStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!prefs.showMenuBar)

            if prefs.menuBarStyle.showsText {
                Section("The number beside it") {
                    Picker("Value", selection: $prefs.menuBarValue) {
                        ForEach(MenuBarValue.allCases) { Text($0.label).tag($0) }
                    }
                }
                .disabled(!prefs.showMenuBar)
            }

            Section("With more than one enclosure") {
                Picker("Follow", selection: $prefs.menuBarFollows) {
                    ForEach(MenuBarFollows.allCases) { Text($0.label).tag($0) }
                }
                Text("Following the fullest is the safer default: the menu bar is a "
                   + "warning light, so it should show whichever box is closest to "
                   + "becoming a problem rather than whichever you happened to click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!prefs.showMenuBar)
        }
        .formStyle(.grouped)
    }

    // MARK: Notifications

    private var notifications: some View {
        Form {
            Section {
                Toggle("Notify me about this enclosure", isOn: $prefs.notificationsEnabled)
            } footer: {
                Text("Notifications fire on a change, not on a condition, so a full "
                   + "array is announced once rather than at every check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tell me when") {
                Toggle("Free space crosses the enclosure's own threshold",
                       isOn: $prefs.notifyCapacity)
                Toggle("A drive is added or removed", isOn: $prefs.notifyBays)
                Toggle("A disk's own health changes", isOn: $prefs.notifyDiskHealth)
                Toggle("The array starts rebuilding, or its status changes",
                       isOn: $prefs.notifyHealth)
                Toggle("An enclosure is connected or disconnected",
                       isOn: $prefs.notifyConnection)
            }
            .disabled(!prefs.notificationsEnabled)

            if !model.recentEvents.isEmpty {
                Section("Recent") {
                    ForEach(model.recentEvents.prefix(8)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.callout.weight(.medium))
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Driver

    private var driver: some View {
        Form {
            Section("Versions") {
                LabeledContent("Carried by this app", value: model.carriedBuild ?? "not found")
                LabeledContent("Installed", value: installedText)
                LabeledContent("Running", value: model.runningBuild ?? "nothing bound")
            }

            if model.restartRequired {
                Section {
                    Label("Restart the Mac to finish installing the driver. macOS keeps "
                        + "running the previous one until then.",
                          systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
            } else if model.installWouldUpgrade {
                Section {
                    Label("This app carries a newer driver than the one installed.",
                          systemImage: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Install Driver") { model.installDriver() }
                        .disabled(model.isInstalling)
                    Button("Check Again") { model.checkDriver() }
                    Spacer()
                    Button("System Settings…") { DriverExtension.openExtensionSettings() }
                }
                if let message = model.installMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Removing it") {
                HStack {
                    Button("Remove Driver…", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .disabled(model.isInstalling || !model.driver.isUsable)
                    Spacer()
                }
                Text("Takes the driver back out of macOS. The enclosure keeps working "
                   + "as ordinary storage — only the management channel goes away — and "
                   + "the Mac has to be restarted to finish. Reinstalling puts it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("Remove the ReDrobo driver?",
                                isPresented: $confirmingRemoval) {
                Button("Remove Driver", role: .destructive) { model.uninstallDriver() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("ReDrobo will not be able to read the enclosure until the driver is "
                   + "installed again. Nothing on the Drobo is touched, and the volume "
                   + "stays mounted.")
            }

            Section("Troubleshooting") {
                HStack {
                    Button("Forget Skipped Records") { model.forgetSkippedRecords() }
                    Spacer()
                }
                Text("ReDrobo stops asking for a record after an enclosure has failed to "
                   + "answer it several polls running, so a firmware that lacks one is not "
                   + "asked every thirty seconds for ever. This throws that list away and "
                   + "asks for everything again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logging") {
                Picker("Level", selection: $prefs.logLevel) {
                    ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
                }
                Text(prefs.logLevel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ReDrobo logs to the unified log, next to the driver's own output. "
                   + "Watch both with:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CommandBlock(command: Log.streamCommand)
            }

            Section("Diagnostics") {
                Toggle("Remove names and serial numbers from reports",
                       isOn: $prefs.redactDiagnostics)
                HStack {
                    DiagnosticsMenu(model: model)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func ms(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "—"
                     : (seconds < 1 ? String(format: "%.0f ms", seconds * 1000)
                                    : String(format: "%.2f s", seconds))
    }

    private var installedText: String {
        switch model.driver {
        case .checking:         return "checking…"
        case .notInstalled:     return "not installed"
        case .awaitingApproval: return "waiting for approval"
        case .error(let why):   return why
        case .installed(let build, let enabled):
            return "\(build ?? "?")\(enabled ? "" : " (not enabled)")"
        }
    }
}
