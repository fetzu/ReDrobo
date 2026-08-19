//  Prefs.swift
//
//  Small, boring, and all in UserDefaults. Two of these settings reach outside
//  the app — the Dock icon and the login item — so both go through here rather
//  than being poked at from a view.

import Foundation
import Observation
import ServiceManagement
import AppKit

/// How much the menu bar item is allowed to say.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case iconOnly, iconAndColour, iconAndText
    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly:      return "Icon only"
        case .iconAndColour: return "Icon, coloured by status"
        case .iconAndText:   return "Icon and capacity"
        }
    }

    var detail: String {
        switch self {
        case .iconOnly:      return "One neutral icon. No colour, no text, no state."
        case .iconAndColour: return "The icon changes shape and colour with the enclosure's health."
        case .iconAndText:   return "As above, with the number beside it."
        }
    }

    var showsStatus: Bool { self != .iconOnly }
    var showsText: Bool { self == .iconAndText }
}

enum MenuBarValue: String, CaseIterable, Identifiable, Sendable {
    case usedPercent, freeSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usedPercent: return "Percentage used"
        case .freeSpace:   return "Free space"
        }
    }
}

enum MenuBarFollows: String, CaseIterable, Identifiable, Sendable {
    case fullest, selected
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullest:  return "Whichever is fullest"
        case .selected: return "The one selected in the window"
        }
    }
}

/// Dashboard printed TiB and wrote TB. Matching that keeps ReDrobo's numbers
/// the same as everyone's muscle memory; the honest option is here for people
/// who would rather have the units be true.
enum CapacityUnits: String, CaseIterable, Identifiable, Sendable {
    case dashboard, decimal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dashboard: return "TB meaning TiB, as Dashboard showed it"
        case .decimal:   return "True decimal TB"
        }
    }
}

/// Whether ReDrobo occupies the Dock.
///
/// Three cases rather than a switch, because "hide it from the Dock" has two
/// reasonable readings: never be in the Dock at all, or only be there while
/// there is a window to click on. The second is what a menu bar utility usually
/// wants — it stays out of the way until you open it, then behaves like a
/// normal app for as long as the window is up.
enum DockVisibility: String, CaseIterable, Identifiable, Sendable {
    case always, whileWindowOpen, never
    var id: String { rawValue }

    var label: String {
        switch self {
        case .always:         return "Always"
        case .whileWindowOpen: return "Only while the window is open"
        case .never:          return "Never, menu bar only"
        }
    }

    var detail: String {
        switch self {
        case .always:
            return "ReDrobo behaves like an ordinary app."
        case .whileWindowOpen:
            return "The Dock icon appears when you open the window and goes away when "
                 + "you close it. ReDrobo keeps polling either way."
        case .never:
            return "ReDrobo lives in the menu bar alone. Open the window from there."
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var label: String { self == .celsius ? "Celsius" : "Fahrenheit" }
}

@Observable
final class Prefs {
    static let shared = Prefs()

    private static let d = UserDefaults.standard

    // Menu bar
    var showMenuBar: Bool            { didSet { Self.d.set(showMenuBar, forKey: "showMenuBar") } }
    var menuBarStyle: MenuBarStyle   { didSet { Self.d.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    var menuBarValue: MenuBarValue   { didSet { Self.d.set(menuBarValue.rawValue, forKey: "menuBarValue") } }
    var menuBarFollows: MenuBarFollows { didSet { Self.d.set(menuBarFollows.rawValue, forKey: "menuBarFollows") } }

    // Application
    var dockVisibility: DockVisibility {
        didSet {
            Self.d.set(dockVisibility.rawValue, forKey: "dockVisibility")
            applyActivationPolicy()
        }
    }

    /// Set by the main window as it comes and goes, so `whileWindowOpen` has
    /// something to key on.
    var mainWindowOpen = false {
        didSet { if mainWindowOpen != oldValue { applyActivationPolicy() } }
    }
    var pollSeconds: Int             { didSet { Self.d.set(pollSeconds, forKey: "pollSeconds") } }

    // Units
    var capacityUnits: CapacityUnits { didSet { Self.d.set(capacityUnits.rawValue, forKey: "capacityUnits") } }
    var temperatureUnit: TemperatureUnit { didSet { Self.d.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }

    // Notifications
    var notificationsEnabled: Bool   { didSet { Self.d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var notifyCapacity: Bool         { didSet { Self.d.set(notifyCapacity, forKey: "notifyCapacity") } }
    var notifyBays: Bool             { didSet { Self.d.set(notifyBays, forKey: "notifyBays") } }
    var notifyHealth: Bool           { didSet { Self.d.set(notifyHealth, forKey: "notifyHealth") } }
    var notifyConnection: Bool       { didSet { Self.d.set(notifyConnection, forKey: "notifyConnection") } }
    var notifyDiskHealth: Bool       { didSet { Self.d.set(notifyDiskHealth, forKey: "notifyDiskHealth") } }

    var redactDiagnostics: Bool      { didSet { Self.d.set(redactDiagnostics, forKey: "redactDiagnostics") } }

    var logLevel: LogLevel {
        didSet {
            Self.d.set(logLevel.rawValue, forKey: "logLevel")
            Log.level = logLevel
            Log.info("log level set to \(logLevel.label)")
        }
    }

    /// Not mirrored into UserDefaults: the real answer lives in SMAppService,
    /// and a stale copy here would be a lie the moment anyone touches the
    /// Login Items pane.
    var openAtLogin: Bool {
        didSet {
            guard openAtLogin != oldValue else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() }
                else           { try SMAppService.mainApp.unregister() }
            } catch {
                loginItemError = error.localizedDescription
                openAtLogin = oldValue
            }
        }
    }
    var loginItemError: String?

    private init() {
        let d = Self.d
        d.register(defaults: [
            "showMenuBar": true,
            "menuBarStyle": MenuBarStyle.iconAndText.rawValue,
            "menuBarValue": MenuBarValue.usedPercent.rawValue,
            "menuBarFollows": MenuBarFollows.fullest.rawValue,
            "dockVisibility": DockVisibility.always.rawValue,
            "pollSeconds": 30,
            "capacityUnits": CapacityUnits.dashboard.rawValue,
            "temperatureUnit": TemperatureUnit.celsius.rawValue,
            "notificationsEnabled": true,
            "notifyCapacity": true,
            "notifyBays": true,
            "notifyHealth": true,
            "notifyDiskHealth": true,
            "notifyConnection": false,
            "redactDiagnostics": true,
            "logLevel": LogLevel.info.rawValue,
        ])
        showMenuBar          = d.bool(forKey: "showMenuBar")
        menuBarStyle         = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .iconAndText
        menuBarValue         = MenuBarValue(rawValue: d.string(forKey: "menuBarValue") ?? "") ?? .usedPercent
        menuBarFollows       = MenuBarFollows(rawValue: d.string(forKey: "menuBarFollows") ?? "") ?? .fullest
        // Migrate the old two-state switch, so anyone who had turned the Dock
        // icon off keeps it off.
        if d.object(forKey: "dockVisibility") == nil,
           d.object(forKey: "showDockIcon") != nil, !d.bool(forKey: "showDockIcon") {
            d.set(DockVisibility.never.rawValue, forKey: "dockVisibility")
        }
        dockVisibility       = DockVisibility(rawValue: d.string(forKey: "dockVisibility") ?? "")
                               ?? .always
        pollSeconds          = d.integer(forKey: "pollSeconds")
        capacityUnits        = CapacityUnits(rawValue: d.string(forKey: "capacityUnits") ?? "") ?? .dashboard
        temperatureUnit      = TemperatureUnit(rawValue: d.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        notificationsEnabled = d.bool(forKey: "notificationsEnabled")
        notifyCapacity       = d.bool(forKey: "notifyCapacity")
        notifyBays           = d.bool(forKey: "notifyBays")
        notifyHealth         = d.bool(forKey: "notifyHealth")
        notifyDiskHealth     = d.bool(forKey: "notifyDiskHealth")
        notifyConnection     = d.bool(forKey: "notifyConnection")
        redactDiagnostics    = d.bool(forKey: "redactDiagnostics")
        logLevel             = LogLevel(rawValue: d.integer(forKey: "logLevel")) ?? .info
        openAtLogin          = SMAppService.mainApp.status == .enabled
        Log.level            = logLevel
    }

    static let pollChoices = [15, 30, 60, 300]

    /// Leaving the Dock turns this into a menu bar app. Refuse to do that while
    /// the menu bar item is also hidden, or there would be no way left to reach
    /// the app at all.
    func applyActivationPolicy() {
        let wantsDock: Bool
        switch dockVisibility {
        case .always:          wantsDock = true
        case .never:           wantsDock = false
        case .whileWindowOpen: wantsDock = mainWindowOpen
        }
        if !wantsDock && !showMenuBar { showMenuBar = true }

        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp?.activationPolicy() != policy else { return }
        NSApp?.setActivationPolicy(policy)
        // Coming back to .regular without this leaves the app frontmost-but-not-
        // focused, with no menu bar of its own.
        if policy == .regular { NSApp?.activate() }
    }

    /// Called before opening the window, so the policy is already right by the
    /// time it appears rather than a frame later.
    func prepareToShowWindow() {
        if dockVisibility == .whileWindowOpen { mainWindowOpen = true }
    }

    // MARK: Formatting that depends on a preference

    func capacity(_ bytes: UInt64) -> String {
        capacityUnits == .dashboard ? Fmt.tib(bytes) : Fmt.diskTB(bytes)
    }

    func temperature(_ celsius: Int) -> String {
        temperatureUnit == .celsius
            ? "\(celsius) °C"
            : "\(Int((Double(celsius) * 9 / 5 + 32).rounded())) °F"
    }
}
