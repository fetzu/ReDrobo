//  MenuBar.swift
//
//  The part that actually stops an array filling up unnoticed. Everything else
//  in the app you have to remember to open; this is in front of you already.
//
//  Three levels of noise, because a status light in the menu bar is a matter of
//  taste: a plain icon that never changes, an icon that changes colour, or that
//  plus the number.

import SwiftUI
import AppKit

// MARK: - Drawing a coloured icon into the menu bar

/// SwiftUI hands MenuBarExtra labels to AppKit as template images, which strips
/// colour. Tinting an NSImage and clearing isTemplate is the only way to keep
/// it, so the icon is built here rather than with Image(systemName:).
private func menuBarIcon(symbol: String, tint: NSColor?) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return NSImage() }

    guard let tint else {
        base.isTemplate = true      // let macOS handle light and dark
        return base
    }

    let size = base.size
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    base.draw(at: .zero, from: CGRect(origin: .zero, size: size),
              operation: .sourceOver, fraction: 1)
    tint.set()
    CGRect(origin: .zero, size: size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.isTemplate = false
    return tinted
}

private extension DroboSnapshot.Health {
    var menuBarTint: NSColor {
        switch self {
        case .good:     return .systemGreen
        case .warning:  return .systemYellow
        case .critical: return .systemRed
        case .unknown:  return .secondaryLabelColor
        }
    }
}

// MARK: - What sits in the menu bar

struct MenuBarLabel: View {
    let model: DroboModel
    @Bindable var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: menuBarIcon(symbol: symbol, tint: tint))
            if let text { Text(text) }
        }
        .accessibilityLabel(accessibility)
    }

    /// Which enclosure the menu bar speaks for. Fullest by default, because the
    /// menu bar is a warning light and should follow whichever box is closest
    /// to becoming a problem.
    private var subject: Enclosure? {
        let live = model.connected.filter { $0.snapshot != nil }
        switch prefs.menuBarFollows {
        case .selected:
            return model.selected.flatMap { $0.snapshot != nil ? $0 : nil } ?? live.first
        case .fullest:
            return live.max { ($0.snapshot?.usedFraction ?? 0) < ($1.snapshot?.usedFraction ?? 0) }
        }
    }

    private var symbol: String {
        guard prefs.menuBarStyle.showsStatus else { return "externaldrive" }
        guard let s = subject?.snapshot else {
            switch model.situation {
            case .driverMissing, .driverAwaitingApproval, .driverDisabled:
                return "puzzlepiece.extension"
            case .unclaimed, .silent, .driverError:
                return "externaldrive.trianglebadge.exclamationmark"
            default:
                return "externaldrive"
            }
        }
        if subject?.hasFailingDisk == true { return "externaldrive.badge.xmark" }
        switch s.health {
        case .good:     return "externaldrive.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown:  return "externaldrive.badge.questionmark"
        }
    }

    private var tint: NSColor? {
        guard prefs.menuBarStyle.showsStatus else { return nil }
        guard let s = subject?.snapshot else { return nil }
        return s.health.menuBarTint
    }

    private var text: String? {
        guard prefs.menuBarStyle.showsText, let s = subject?.snapshot else { return nil }
        switch prefs.menuBarValue {
        case .usedPercent: return "\(s.usedPercent)%"
        case .freeSpace:   return prefs.capacity(s.freeBytes)
        }
    }

    private var accessibility: String {
        guard let e = subject, let s = e.snapshot else { return "ReDrobo, no enclosure" }
        return "\(e.displayName), \(s.usedPercent) percent used, "
             + "\(Prefs.shared.capacity(s.freeBytes)) free"
    }
}

// MARK: - The panel it opens

struct MenuBarPanel: View {
    let model: DroboModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.enclosures.isEmpty {
                emptyState
            } else {
                ForEach(model.enclosures) { enclosure in
                    EnclosureTile(enclosure: enclosure)
                    if enclosure.id != model.enclosures.last?.id { Divider() }
                }
            }

            Divider()

            // Icon controls on one line, the two text actions on the next.
            // Settings sitting between "Open ReDrobo" and "Quit" read as a third
            // peer of the same kind, which it is not.
            HStack {
                if let at = model.lastRefresh {
                    Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh now")

                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            HStack(spacing: 8) {
                Button("Open ReDrobo") {
                    Prefs.shared.prepareToShowWindow()
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 310)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline).font(.body.weight(.medium))
            Text(subhead).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch model.situation {
        case .checking:               return "Checking…"
        case .reading:                return "Reading the enclosure…"
        case .driverMissing:          return "Driver not installed"
        case .driverAwaitingApproval: return "Waiting for approval"
        case .driverDisabled:         return "Driver switched off"
        case .driverError:            return "Driver state unknown"
        case .unclaimed:              return "Drobo not claimed by the driver"
        case .silent:                 return "No answer from the enclosure"
        default:                      return "No Drobo connected"
        }
    }

    private var subhead: String {
        switch model.situation {
        case .noEnclosure:
            return "The driver is installed and working. Nothing is plugged in."
        case .driverMissing, .driverAwaitingApproval, .driverDisabled, .driverError:
            return "Open ReDrobo to sort it out."
        case .unclaimed:
            return "Restart the Mac if you have just installed the driver."
        default:
            return "Open ReDrobo for the detail."
        }
    }
}

// MARK: - One enclosure, compactly

private struct EnclosureTile: View {
    let enclosure: Enclosure
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: enclosure.health.symbol)
                    .foregroundStyle(enclosure.isConnected ? enclosure.health.tint : .secondary)
                Text(enclosure.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let s = enclosure.snapshot {
                    Text("\(s.usedPercent)%")
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let s = enclosure.snapshot {
                CapacityBar(fraction: s.usedFraction,
                            threshold: Double(s.yellowThresholdPercent) / 100,
                            tint: enclosure.isConnected ? s.health.tint : .secondary)

                Text("\(prefs.capacity(s.usedBytes)) of \(prefs.capacity(s.totalBytes)) used · "
                   + "\(prefs.capacity(s.freeBytes)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                BayDots(bays: s.driveBays)

                if let worst = s.activeAlerts.first {
                    Label(worst.name, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !enclosure.isConnected {
                Text("Disconnected · last seen "
                   + enclosure.lastSeen.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .opacity(enclosure.isConnected ? 1 : 0.6)
    }
}

private struct CapacityBar: View {
    let fraction: Double
    let threshold: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                if threshold > 0 && threshold < 1 {
                    Rectangle()
                        .fill(.primary.opacity(0.4))
                        .frame(width: 1)
                        .offset(x: geo.size.width * threshold)
                }
            }
        }
        .frame(height: 8)
    }
}

/// One square per bay, in slot order, coloured by that disk's own health where
/// the enclosure reports it. Enough to notice a drive has gone, or gone bad,
/// without opening anything.
private struct BayDots: View {
    let bays: [DriveBay]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(bays) { bay in
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill(for: bay))
                    .frame(width: 14, height: 6)
                    .help(tooltip(for: bay))
            }
        }
    }

    private func fill(for bay: DriveBay) -> AnyShapeStyle {
        if bay.isEmpty { return AnyShapeStyle(.quaternary) }
        guard bay.extended else { return AnyShapeStyle(Color.green.gradient) }
        switch bay.health {
        case .good:    return AnyShapeStyle(Color.green.gradient)
        case .healed:  return AnyShapeStyle(Color.teal.gradient)
        case .warning: return AnyShapeStyle(Color.yellow.gradient)
        case .failed:  return AnyShapeStyle(Color.red.gradient)
        }
    }

    private func tooltip(for bay: DriveBay) -> String {
        if bay.isEmpty { return "\(bay.label): empty" }
        var parts = ["\(bay.label): \(bay.model), \(bay.displayCapacity)"]
        if bay.extended { parts.append(bay.health.label) }
        if let t = bay.temperatureC { parts.append(Prefs.shared.temperature(t)) }
        return parts.joined(separator: " · ")
    }
}
