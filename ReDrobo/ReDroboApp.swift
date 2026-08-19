//  ReDroboApp.swift
//
//  ReDrobo. One app: it carries the driver, installs it, and shows what the
//  enclosure reports. A driver extension can only be activated by the app it
//  ships inside, so splitting the two would not work even if it were tidier.
//
//  Three scenes. The window is the dashboard, the menu bar item is the part
//  that gets looked at without being opened, and Settings holds the switches.

import SwiftUI

@main
struct ReDroboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // @Bindable rather than a Bindable built inline: MenuBarExtra reads the
        // binding while the scene is evaluated, and that read is what registers
        // the dependency that makes the toggle take effect without a relaunch.
        @Bindable var prefs = Prefs.shared

        Window("ReDrobo", id: "main") {
            ContentView(model: DroboModel.shared)
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Export Diagnostics…") { exportDiagnostics() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { DroboModel.shared.refreshNow() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra(isInserted: $prefs.showMenuBar) {
            MenuBarPanel(model: DroboModel.shared)
        } label: {
            MenuBarLabel(model: DroboModel.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: DroboModel.shared)
        }
    }

    private func exportDiagnostics() {
        Task { @MainActor in
            let text = await Diagnostics.report(model: DroboModel.shared,
                                                redacted: Prefs.shared.redactDiagnostics)
            Diagnostics.save(text, suggested: "ReDrobo-diagnostics.txt")
        }
    }
}

// MARK: - Launch and lifetime

/// SwiftUI has no scene-independent launch hook, and polling has to start
/// whether or not a window is open: with the Dock icon turned off there may
/// never be one.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        DroboModel.shared.bootstrap()
    }

    /// Closing the window is not quitting when the menu bar item is the point
    /// of the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Prefs.shared.showMenuBar
    }
}
