//  ContentView.swift
//
//  Liquid Glass, macOS 26. Five panes: an overview, the drive bays, the volume
//  as macOS sees it, the decoded status word, and the raw records. The panes
//  show one enclosure at a time; the picker in the toolbar appears only when
//  there is more than one to choose between.

import SwiftUI

// MARK: - Shared bits

extension DroboSnapshot.Health {
    var tint: Color {
        switch self {
        case .good:     return .green
        case .warning:  return .yellow
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .good:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown:  return "questionmark.circle.fill"
        }
    }
}

extension DiskHealth {
    var tint: Color {
        switch self {
        case .good:    return .green
        case .healed:  return .teal
        case .warning: return .yellow
        case .failed:  return .red
        }
    }
    var symbol: String {
        switch self {
        case .good:    return "checkmark.circle.fill"
        case .healed:  return "bandage.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.octagon.fill"
        }
    }
}

/// A glass card. Everything in the app sits in one of these.
struct Card<Content: View>: View {
    var title: String? = nil
    var prominent = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(prominent ? 24 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(prominent ? .regular.tint(.accentColor.opacity(0.10)) : .regular,
                     in: .rect(cornerRadius: prominent ? 20 : 16))
    }
}

/// A label and a value, where the value is click-to-copy. Serial numbers and
/// status words are exactly the things you want to paste into a search or a
/// forum post, and selecting text with the mouse to get them is a chore.
/// A label and a value, and every value in the app goes through here.
///
/// It carries two things that used to be separate views, which is why the
/// Enclosure card did not line up: a value can be click-to-copy, and a value
/// can be waiting on a record that has not arrived. The copy affordance takes
/// the same width whether it is visible or not, so a copyable row and a
/// non-copyable one share a trailing edge.
struct Row: View {
    let label: String
    var value: String = ""
    var mono = false
    var copyable = true
    /// Where the record behind this value stands. Defaults to present, because
    /// most values do not come from a record that can be outstanding.
    var state: Enclosure.RecordState = .present

    @State private var copied = false
    @State private var hovering = false

    private var isCopyable: Bool {
        copyable && state == .present && !value.isEmpty && value != "—"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)

            if isCopyable {
                Button(action: copy) { text }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help(copied ? "Copied" : "Click to copy")
                    .contextMenu { Button("Copy") { copy() } }
            } else {
                content
            }

            // Always present, so it cannot shift the text it sits beside.
            Image(systemName: copied ? "checkmark" : "document.on.document")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .opacity(isCopyable && (copied || hovering) ? 1 : 0)
                .frame(width: 11)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .present:
            text
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…").foregroundStyle(.secondary)
            }
        case .noAnswer:
            Text("Did not answer").foregroundStyle(.tertiary).font(.callout)
        case .unavailable:
            Text("Not available on this firmware")
                .foregroundStyle(.tertiary).font(.callout)
        }
    }

    private var text: some View {
        Text(value)
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy) { copied = false }
        }
    }
}


/// Something to say at the top of a pane that is not about the pane itself:
/// the enclosure has gone, or the driver on disk is not the one running.
struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }
}

// MARK: - Capacity ring

struct CapacityRing: View {
    let snapshot: DroboSnapshot
    var lineWidth: CGFloat = 26
    var diameter: CGFloat = 200

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: snapshot.usedFraction)
                .stroke(snapshot.health.tint.gradient,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: snapshot.usedFraction)

            // The enclosure's own warning threshold, drawn as a tick across the
            // stroke rather than near it: the ring is inset by half its width,
            // so the tick has to sit on that radius to line up.
            if snapshot.yellowThresholdPercent > 0 {
                Rectangle()
                    .fill(.primary.opacity(0.35))
                    .frame(width: 2, height: lineWidth + 6)
                    .offset(y: -(diameter / 2 - lineWidth / 2))
                    .rotationEffect(.degrees(Double(snapshot.yellowThresholdPercent) / 100 * 360))
            }

            VStack(spacing: 2) {
                Text("\(snapshot.usedPercent)%")
                    .font(.system(size: diameter * 0.22, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(8)
    }
}

// MARK: - Drive bays

struct BayView: View {
    let bay: DriveBay
    @State private var expanded = false
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(indicator)
                    .frame(width: 6, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bay.label).font(.body.weight(.medium))
                        if bay.extended && bay.health != .good {
                            Image(systemName: bay.health.symbol)
                                .font(.caption)
                                .foregroundStyle(bay.health.tint)
                        }
                    }
                    Text(bay.isEmpty ? "No drive installed" : subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let t = bay.temperatureC {
                    Text(prefs.temperature(t))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(bay.displayCapacity)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()

                if hasDetail {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide details" : "Show details")
                }
            }
            .padding(.vertical, 6)

            if expanded, hasDetail { detail }
        }
    }

    private var indicator: AnyShapeStyle {
        if bay.isEmpty { return AnyShapeStyle(.quaternary) }
        guard bay.extended else { return AnyShapeStyle(Color.green.gradient) }
        return AnyShapeStyle(bay.health.tint.gradient)
    }

    /// Name what is outstanding rather than saying "loading". Each of these is
    /// a separate round trip to the enclosure and they can take seconds each.
    private func pendingSummary(_ e: Enclosure) -> String {
        let outstanding = ESARecord.allCases
            .filter { e.state(of: $0) == .reading }
            .map(\.label)
        guard !outstanding.isEmpty else { return "Almost done." }
        let list = outstanding.count <= 3
            ? outstanding.joined(separator: ", ")
            : outstanding.prefix(3).joined(separator: ", ")
              + " and \(outstanding.count - 3) more"
        return "Values from these records are not in yet: \(list)."
    }

    private var subtitle: String {
        var parts = [bay.model]
        if bay.extended { parts.append(bay.kind.label) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var hasDetail: Bool { bay.extended && !bay.isEmpty }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "Health", value: bay.health.label)
            if !bay.serial.isEmpty { Row(label: "Serial", value: bay.serial, mono: true) }
            if !bay.firmwareRevision.isEmpty {
                Row(label: "Firmware", value: bay.firmwareRevision, mono: true)
            }
            if let life = bay.lifeRemainingPercent {
                Row(label: "Life remaining", value: "\(life)%")
            }
            if bay.rotationalSpeed > 0 {
                Row(label: "Rotational speed", value: "\(bay.rotationalSpeed)")
            }
            Row(label: "Errors seen", value: "\(bay.errorCount)")
            if bay.managedCapacityBytes > 0 {
                Row(label: "Managed capacity", value: Prefs.shared.capacity(bay.managedCapacityBytes))
            }
        }
        .font(.callout)
        .padding(.leading, 20)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Panes

struct OverviewPane: View {
    let enclosure: Enclosure
    let snapshot: DroboSnapshot
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    HStack(alignment: .center, spacing: 28) {
                        CapacityRing(snapshot: snapshot)

                        VStack(alignment: .leading, spacing: 14) {
                            Label {
                                Text(snapshot.healthLabel).font(.title3.weight(.semibold))
                            } icon: {
                                Image(systemName: snapshot.health.symbol)
                                    .foregroundStyle(snapshot.health.tint)
                            }

                            Divider()

                            Row(label: "Free", value: prefs.capacity(snapshot.freeBytes))
                            Row(label: "Used", value: prefs.capacity(snapshot.usedBytes))
                            Row(label: "Total", value: prefs.capacity(snapshot.totalBytes))

                            switch enclosure.state(of: .options) {
                            case .present where snapshot.yellowThresholdPercent > 0:
                                Text(thresholdNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            case .reading:
                                Text("Reading the enclosure's own thresholds…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            default:
                                EmptyView()
                            }
                        }
                    }
                }

                if !snapshot.activeAlerts.isEmpty {
                    Card(title: "The enclosure is reporting") {
                        ForEach(snapshot.activeAlerts) { bit in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bit.name).font(.body.weight(.medium))
                                    Text(bit.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(snapshot.health.tint)
                            }
                        }
                    }
                }

                Card(title: "Enclosure") {
                    Row(label: "Name", value: snapshot.name)
                    Row(label: "Model", value: enclosure.modelName)
                    if !snapshot.serial.isEmpty {
                        Row(label: "Serial", value: snapshot.serial, mono: true)
                    } else if let serial = enclosure.serial {
                        Row(label: "Serial", value: serial, mono: true)
                    }
                    Row(label: "Firmware",
                        value: "\(snapshot.firmwareVersion) (build \(snapshot.firmwareBuild))",
                        state: enclosure.state(of: .firmware))
                    Row(label: "Platform", value: snapshot.platform,
                        state: enclosure.state(of: .firmware))
                    Row(label: "Built", value: snapshot.firmwareBuiltOn,
                        state: enclosure.state(of: .firmware))
                    Row(label: "Clock", value: clockText)
                    Row(label: "Volumes", value: "\(snapshot.lunCount)",
                        state: enclosure.state(of: .luns))
                    if snapshot.isRelayouting {
                        Label("Rebuilding, \(snapshot.relayoutCount) relayouts",
                              systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(20)
        }
    }

    private var thresholdNote: String {
        snapshot.redThresholdPercent > 0
            ? "The enclosure warns at \(snapshot.yellowThresholdPercent)% and turns red at \(snapshot.redThresholdPercent)%."
            : "The enclosure warns at \(snapshot.yellowThresholdPercent)%."
    }

    /// The enclosure keeps its own wall clock and the offset separately, so
    /// this prints the clock face it believes in rather than converting it.
    private var clockText: String {
        let hours = Double(snapshot.gmtOffsetMinutes) / 60
        let sign = hours < 0 ? "" : "+"
        return "\(snapshot.deviceClock)  UTC\(sign)\(hours.formatted(.number.precision(.fractionLength(0...1))))"
    }
}

struct BaysPane: View {
    let enclosure: Enclosure
    let snapshot: DroboSnapshot
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Drive bays") {
                    VStack(spacing: 0) {
                        ForEach(snapshot.driveBays) { bay in
                            BayView(bay: bay)
                            if bay.id != snapshot.driveBays.last?.id { Divider() }
                        }
                    }
                    switch enclosure.state(of: .slots2) {
                    case .reading:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading per-disk health, serial numbers and firmware…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    case .noAnswer, .unavailable:
                        Text("This firmware does not answer the extended slot record, so "
                           + "per-disk health, serial numbers and temperature are not "
                           + "available. Capacity and model are.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .present:
                        EmptyView()
                    }
                }

                if let accel = snapshot.accelerator {
                    Card(title: "Hot data cache") {
                        BayView(bay: accel)
                        Text("An mSATA SSD used to accelerate frequently read data. It is "
                           + "not part of the protected pack.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ProtectionCard(snapshot: snapshot)
            }
            .padding(20)
        }
    }
}

/// What BeyondRAID is doing with the disks. Everything here except the
/// redundancy level is a number the enclosure reports; the level itself is
/// derived from them and labelled as such.
struct ProtectionCard: View {
    let snapshot: DroboSnapshot
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        Card(title: "Protection") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.isProtected
                         ? "The array can survive a disk failure"
                         : "The array cannot survive a disk failure")
                        .font(.body.weight(.medium))
                    Text(snapshot.isProtected
                         ? "Reported directly by the enclosure."
                         : "The enclosure has cleared its redundancy bit. Do not remove a disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: snapshot.isProtected ? "checkmark.shield.fill"
                                                       : "exclamationmark.shield.fill")
                    .foregroundStyle(snapshot.isProtected ? .green : .red)
            }

            Divider()

            Row(label: "Level", value: snapshot.redundancyLabel)
            Row(label: "Raw installed", value: Fmt.diskTB(snapshot.rawInstalledBytes))
            Row(label: "Usable, protected", value: prefs.capacity(snapshot.totalBytes))
            if snapshot.unprotectedTotalBytes > 0 {
                Row(label: "Usable, unprotected",
                    value: prefs.capacity(snapshot.unprotectedTotalBytes))
            }
            Row(label: "Held back for redundancy",
                value: Fmt.diskTB(snapshot.reservedForProtectionBytes))
            Row(label: "Usable share",
                value: String(format: "%.0f%% of the disks", snapshot.usableFraction * 100))

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The level is worked out, not read")
                        .font(.callout.weight(.medium))
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var explanation: String {
        let base = "No decoded record carries the redundancy level, and nothing Drobo "
                 + "shipped reads one either. ReDrobo works it out from what the pack "
                 + "holds back: BeyondRAID reserves the largest disk for single "
                 + "redundancy and the two largest for dual, which are a factor of two "
                 + "apart and so hard to confuse. "
        guard let fit = snapshot.redundancyFit else {
            return base + "These capacities do not fit either case closely enough to "
                        + "call, so ReDrobo will not guess."
        }
        return base + String(format: "Here the numbers fit to within %.1f%%.",
                             abs(fit - 1) * 100)
    }
}

/// The pane that earns its place: macOS believes the thin provisioned lie, and
/// this is where the truth is stated first and the lie is labelled as one.
struct VolumePane: View {
    let enclosure: Enclosure
    let snapshot: DroboSnapshot
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(prominent: true) {
                    Text("What is actually there")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 28) {
                        CapacityRing(snapshot: snapshot, lineWidth: 20, diameter: 150)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(prefs.capacity(snapshot.freeBytes))
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText())
                            Text("free of \(prefs.capacity(snapshot.totalBytes))")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Straight from the enclosure, over the management channel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        Spacer()
                    }
                }

                if let v = enclosure.volume, v.freeBytes > snapshot.freeBytes {
                    Card {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("macOS thinks there is \(prefs.capacity(v.freeBytes)) free — "
                                   + "\(prefs.capacity(v.freeBytes - snapshot.freeBytes)) more than there is.")
                                    .font(.body.weight(.medium))
                                Text("A Drobo advertises a large thin provisioned volume, so the "
                                   + "filesystem cannot know the real limit. Copy until the "
                                   + "Finder says it is full and the array fills up first.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                Card(title: "The volume macOS mounted") {
                    if let v = enclosure.volume {
                        Row(label: "Volume", value: v.name)
                        Row(label: "Device", value: v.device, mono: true)
                        Row(label: "Reported size", value: prefs.capacity(v.totalBytes))
                        Row(label: "Reported free", value: prefs.capacity(v.freeBytes))
                    } else if enclosure.wholeDisk != nil {
                        Text("This enclosure's volume is not mounted.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No volume could be matched to this enclosure.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// The status word, the feature bits and the settings the enclosure keeps.
/// Everything here is decoded from Drobo's own code; anything that is not
/// understood says so rather than being hidden.
struct StatusPane: View {
    let enclosure: Enclosure
    let snapshot: DroboSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Status word") {
                    Row(label: "Value",
                        value: String(format: "0x%08X", snapshot.statusWord), mono: true)
                    Row(label: "Severity", value: severityLabel)
                    if snapshot.diskPackStatus != 0 {
                        Row(label: "Disk pack status",
                            value: String(format: "0x%08X", snapshot.diskPackStatus), mono: true)
                    }
                    Row(label: "Relayouts", value: "\(snapshot.relayoutCount)")

                    Divider()

                    let bits = DroboStatus.decompose(UInt64(snapshot.statusWord))
                    if bits.isEmpty {
                        Text("No bits set.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(bits, id: \.bit) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text("bit \(entry.bit)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name ?? "Not named by Drobo's own code")
                                        .font(.callout)
                                        .foregroundStyle(entry.name == nil ? .secondary : .primary)
                                    if let detail = entry.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }

                    Text("Names come from Drobo's own alert code. A healthy 5D reports "
                       + "0x00028000, whose two bits appear in no alert path, so what they "
                       + "mean is honestly unknown. See docs/PROTOCOL.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Feature flags") {
                    Row(label: "Value",
                        value: String(format: "0x%016llX", snapshot.featureFlags), mono: true)
                    ForEach(FeatureState.named(in: snapshot.featureFlags), id: \.rawValue) { f in
                        Row(label: String(format: "bit %d",
                                          f.rawValue.trailingZeroBitCount), value: f.label)
                    }
                    let unnamed = FeatureState.unnamed(in: snapshot.featureFlags)
                    if !unnamed.isEmpty {
                        Row(label: "Set but unexplained",
                            value: unnamed.map(String.init).joined(separator: ", "))
                    }
                    Text("Options2's featureOnOffStates: what is switched on. Only bit 3 is "
                       + "decoded by anything Drobo shipped, and nothing writes this field "
                       + "except the Pro and FS iSCSI path — so on a directly attached "
                       + "enclosure the remaining bits cannot be identified by changing "
                       + "settings either. They are shown, not guessed at.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "System info, sub-page 0x33") {
                    Text("Three unnamed words. One of them may be the firmware feature "
                       + "table, which is decoded but whose home is unknown. Each is "
                       + "tested below against two things this enclosure demonstrably "
                       + "does.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    switch enclosure.state(of: .systemInfo) {
                    case .reading:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    case .noAnswer, .unavailable:
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("This enclosure does not answer 0x33")
                                    .font(.body.weight(.medium))
                                Text("So the firmware feature table is not there either, "
                                   + "and that avenue is closed. Nothing depends on it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                    case .present where snapshot.featureTableCandidates.isEmpty:
                        // Belt and braces: the record arrived but produced no
                        // words, which should be impossible. Saying so beats
                        // rendering an empty card, which is what this did when
                        // the decode was accidentally missing altogether.
                        Text("The record answered but decoded to nothing, which is a bug. "
                           + "The raw bytes are in the diagnostics report.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    case .present:
                        ForEach(snapshot.featureTableCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                Row(label: "Word \(candidate.index)",
                                    value: String(format: "0x%08X", candidate.value), mono: true)
                                Text(candidate.verdict)
                                    .font(.caption)
                                    .foregroundStyle(candidate.fits ? .green : .secondary)

                                ForEach(candidate.criteria) { c in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: c.agrees ? "checkmark" : "xmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(c.agrees ? Color.green : .orange)
                                        Text(c.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !c.decisive {
                                            Text("inferred")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }

                                if candidate.fits {
                                    Text("Would mean: " + candidate.features
                                            .map(\.label).joined(separator: ", "))
                                        .font(.caption)
                                    if !candidate.unnamedBits.isEmpty {
                                        Text("Plus bits "
                                           + candidate.unnamedBits.map(String.init)
                                                .joined(separator: ", ")
                                           + ", which no recovered accessor names.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }

                Card(title: "Settings the enclosure keeps") {
                    Row(label: "Yellow threshold", value: "\(snapshot.yellowThresholdPercent)%")
                    Row(label: "Red threshold", value: "\(snapshot.redThresholdPercent)%")
                    if snapshot.spinDownDelay > 0 {
                        Row(label: "Spin down delay", value: "\(snapshot.spinDownDelay) minutes")
                    }
                    Row(label: "Protocol version", value: snapshot.protocolVersion)
                    Row(label: "Slots", value: "\(snapshot.slotCount)")
                    Row(label: "Volumes", value: "\(snapshot.lunCount) of max \(snapshot.maxLuns)")
                }
            }
            .padding(20)
        }
    }

    private var severityLabel: String {
        switch snapshot.severity {
        case .red:    return "Red — the enclosure wants attention"
        case .yellow: return "Yellow — worth looking at"
        case .green:  return "Green — nothing to report"
        }
    }
}

struct RecordsPane: View {
    let model: DroboModel
    let snapshot: DroboSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Raw records") {
                    Text("MODE SENSE(10), vendor page 0x3A. The sub-page selects the "
                       + "record. See docs/PROTOCOL.md.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        DiagnosticsMenu(model: model)
                        Spacer()
                    }
                }
                ForEach(ESARecord.allCases, id: \.rawValue) { rec in
                    if let data = snapshot.raw[rec.rawValue] {
                        Card(title: String(format: "0x%02X  ", rec.rawValue) + rec.label) {
                            Text(hexPreview(data))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// Only the part the device says is valid; everything past that is stale
    /// buffer contents rather than data, and on a live enclosure that stale
    /// buffer is its own event log in plain text.
    private func hexPreview(_ d: Data) -> String {
        Hex.dump(d, limit: min(Redaction.printableLength(d, redacted: false), 4 + 256))
    }
}

// MARK: - The overflow menu

/// Settings belongs in the app menu under Command-comma, and it is there. This
/// is the second way to reach it, for the same reason Apple's own menu bar
/// extras carry one: with the Dock icon turned off there is no app menu to use.
struct AppMenu: View {
    let model: DroboModel
    var showSetup: () -> Void = {}

    var body: some View {
        Menu {
            Button("Setup Assistant…", action: showSetup)
            Divider()
            Button("Export Diagnostics…") { export() }
            Button("Copy Diagnostics to Clipboard") { export(save: false) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func export(save: Bool = true) {
        Task {
            let text = await Diagnostics.report(model: model,
                                                redacted: Prefs.shared.redactDiagnostics)
            if save { Diagnostics.save(text, suggested: "ReDrobo-diagnostics.txt") }
            else    { Diagnostics.copyToPasteboard(text) }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsMenu: View {
    let model: DroboModel
    @State private var working = false

    var body: some View {
        Menu {
            Button("Save Report…") { export(save: true) }
            Button("Copy Report to Clipboard") { export(save: false) }
            Divider()
            Toggle("Remove names and serials", isOn: Bindable(Prefs.shared).redactDiagnostics)
        } label: {
            Label("Diagnostics", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(working)
    }

    private func export(save: Bool) {
        working = true
        Task {
            let text = await Diagnostics.report(model: model,
                                                redacted: Prefs.shared.redactDiagnostics)
            working = false
            if save {
                Diagnostics.save(text, suggested: "ReDrobo-diagnostics.txt")
            } else {
                Diagnostics.copyToPasteboard(text)
            }
        }
    }
}

// MARK: - Everything that is not panes of data

/// One screen per reason there is nothing to show. Splitting these apart is the
/// whole point: "the driver is missing" and "nothing is plugged in" are not the
/// same problem and used to produce the same sentence.
struct SituationView: View {
    let model: DroboModel
    var showSetup: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(tint)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if case .unclaimed(let devices) = model.situation {
                Card(title: "What is attached") {
                    ForEach(devices) { d in
                        Row(label: "\(d.vendor) \(d.product)",
                            value: "revision \(d.revision)", mono: true)
                    }
                    Text("The driver carries all 26 Vendor and Product pairs Drobo's own "
                       + "kext matched on. If yours is listed above but not claimed, a "
                       + "restart is usually the answer; if it is a pair the kext never "
                       + "had, the diagnostics report has it ready to paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                ForEach(actions, id: \.0) { label, prominent, run in
                    if prominent {
                        Button(label, action: run).buttonStyle(.glassProminent)
                    } else {
                        Button(label, action: run).buttonStyle(.glass)
                    }
                }
            }
            .disabled(model.isInstalling)

            if let message = model.installMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The words

    private var symbol: String {
        switch model.situation {
        case .checking:               return "hourglass"
        case .reading:                return "arrow.trianglehead.2.clockwise"
        case .ready:                  return "checkmark.circle"
        case .driverMissing:          return "puzzlepiece.extension"
        case .driverAwaitingApproval: return "hand.raised"
        case .driverDisabled:         return "puzzlepiece.extension"
        case .driverError:            return "exclamationmark.triangle"
        case .noEnclosure:            return "cable.connector.slash"
        case .unclaimed:              return "externaldrive.badge.questionmark"
        case .silent:                 return "externaldrive.trianglebadge.exclamationmark"
        }
    }

    private var tint: Color {
        switch model.situation {
        case .driverError, .silent: return .orange
        case .unclaimed:            return .yellow
        default:                    return .secondary
        }
    }

    private var title: String {
        switch model.situation {
        case .checking:               return "Checking…"
        case .reading:                return "Reading the enclosure…"
        case .ready:                  return "Reading…"
        case .driverMissing:          return "Driver not installed"
        case .driverAwaitingApproval: return "Waiting for your approval"
        case .driverDisabled:         return "The driver is switched off"
        case .driverError:            return "macOS would not say"
        case .noEnclosure:            return "No Drobo connected"
        case .unclaimed:              return "A Drobo is connected, but the driver has not taken it"
        case .silent:                 return "The enclosure did not answer"
        }
    }

    private var detail: String {
        switch model.situation {
        case .checking:
            return "Asking macOS about the ReDrobo driver."
        case .reading:
            return "The driver has the enclosure and is reading it. This takes a few "
                 + "seconds the first time; after that most of it is cached."
        case .ready:
            return "Reading the enclosure."
        case .driverMissing:
            return "ReDrobo needs its driver installed before it can talk to an "
                 + "enclosure. macOS will ask you to approve it, and the Mac has to "
                 + "be restarted afterwards."
        case .driverAwaitingApproval:
            return "The driver is installed but macOS is holding it until you approve "
                 + "it in System Settings, under General ▸ Login Items & Extensions ▸ "
                 + "Driver Extensions."
        case .driverDisabled:
            return "The driver is installed but not enabled. Turn it back on in System "
                 + "Settings, under General ▸ Login Items & Extensions ▸ Driver "
                 + "Extensions."
        case .driverError(let why):
            return why
        case .noEnclosure:
            return "The driver is installed and working. Connect a Drobo over USB and "
                 + "switch it on, and it will appear here within a few seconds. "
                 + "Nothing is wrong with the driver."
        case .unclaimed:
            return "macOS can see the enclosure, but ReDrobo's driver is not the one "
                 + "handling it. If you have just installed or updated the driver, "
                 + "restart the Mac: macOS keeps running the previous one until then."
        case .silent(let why):
            return why
        }
    }

    private var actions: [(String, Bool, () -> Void)] {
        switch model.situation {
        case .driverMissing:
            return [("Install Driver", true, { model.installDriver() })]
        case .driverAwaitingApproval, .driverDisabled:
            return [("Open System Settings", true, { DriverExtension.openExtensionSettings() }),
                    ("Check Again", false, { model.checkDriver() })]
        case .driverError:
            return [("Try Again", true, { model.checkDriver() })]
        case .noEnclosure:
            return [("Check Again", false, { model.refreshNow() })]
        case .unclaimed:
            return [("Install Driver", true, { model.installDriver() }),
                    ("Setup Assistant…", false, showSetup),
                    ("Check Again", false, { model.refreshNow() })]
        case .silent:
            return [("Try Again", true, { model.refreshNow() })]
        default:
            return []
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @Bindable var model: DroboModel
    @State private var pane: Pane? = .overview
    @State private var showingSetup = false
    @Environment(\.openSettings) private var openSettings

    enum Pane: String, CaseIterable, Identifiable {
        case overview, bays, volume, status, records
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .bays:     return "Drive Bays"
            case .volume:   return "Volume"
            case .status:   return "Status"
            case .records:  return "Raw Records"
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.67percent"
            case .bays:     return "internaldrive"
            case .volume:   return "externaldrive.connected.to.line.below"
            case .status:   return "stethoscope"
            case .records:  return "curlybraces"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(Pane.allCases, selection: $pane) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
                Divider()
                // Settings is in the app menu under Command-comma where macOS
                // expects it. This is the second way in, and it earns its place:
                // with the Dock icon turned off there is no app menu to use.
                HStack {
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205)
        } detail: {
            detail
                .navigationTitle(model.selected?.displayName ?? "ReDrobo")
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
        }
        // The Dock icon can follow the window's lifetime, so the window has to
        // say when it starts and stops existing.
        .onAppear { Prefs.shared.mainWindowOpen = true }
        .onDisappear { Prefs.shared.mainWindowOpen = false }
        .sheet(isPresented: $showingSetup) {
            VStack(spacing: 0) {
                SetupView(model: model)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingSetup = false }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 760, height: 640)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let enclosure = model.selected, let snapshot = enclosure.snapshot {
            VStack(spacing: 0) {
                if !enclosure.isConnected {
                    Banner(symbol: "cable.connector.slash", tint: .orange,
                           title: "\(enclosure.displayName) is no longer connected",
                           detail: "These are the last figures ReDrobo read, at "
                                 + enclosure.lastSeen.formatted(date: .omitted, time: .shortened)
                                 + ".")
                        .padding([.horizontal, .top], 20)
                }
                if enclosure.isStillReading && enclosure.isConnected {
                    Card {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Still reading the enclosure")
                                    .font(.body.weight(.medium))
                                Text(pendingSummary(enclosure))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding([.horizontal, .top], 20)
                }
                if !snapshot.hasCapacity {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "Capacity could not be read",
                           detail: "The enclosure did not answer the capacity record on the "
                                 + "last poll, so every figure derived from it is missing "
                                 + "rather than zero. Everything else below is current.")
                        .padding([.horizontal, .top], 20)
                }
                if model.restartRequired {
                    Banner(symbol: "arrow.clockwise.circle", tint: .yellow,
                           title: "Restart to finish installing the driver",
                           detail: "Build \(model.installedBuild ?? "?") is installed but "
                                 + "build \(model.runningBuild ?? "?") is still running. "
                                 + "macOS does not replace a driver until the Mac restarts.")
                        .padding([.horizontal, .top], 20)
                }

                switch pane ?? .overview {
                case .overview: OverviewPane(enclosure: enclosure, snapshot: snapshot)
                case .bays:     BaysPane(enclosure: enclosure, snapshot: snapshot)
                case .volume:   VolumePane(enclosure: enclosure, snapshot: snapshot)
                case .status:   StatusPane(enclosure: enclosure, snapshot: snapshot)
                case .records:  RecordsPane(model: model, snapshot: snapshot)
                }
            }
        } else if model.needsSetup {
            SetupView(model: model)
        } else {
            SituationView(model: model) { showingSetup = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.enclosures.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Enclosure", selection: $model.selectedID) {
                    ForEach(model.enclosures) { e in
                        Text(e.isConnected ? e.displayName : "\(e.displayName) (disconnected)")
                            .tag(Optional(e.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // The spinner goes inside the button rather than replacing it, so
            // the toolbar's glass pill keeps the width it has when idle. A bare
            // small ProgressView collapses it to a sliver.
            Button {
                model.refreshNow()
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .opacity(model.isRefreshing ? 0 : 1)
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 20, height: 18)
            }
            .disabled(model.isRefreshing)
            .help(model.isRefreshing ? "Reading the enclosure" : "Refresh")
        }
        ToolbarItem(placement: .primaryAction) {
            AppMenu(model: model) { showingSetup = true }
        }
    }

    /// Name what is outstanding rather than saying "loading". Each of these is
    /// a separate round trip to the enclosure and they can take seconds each.
    private func pendingSummary(_ e: Enclosure) -> String {
        let outstanding = ESARecord.allCases
            .filter { e.state(of: $0) == .reading }
            .map(\.label)
        guard !outstanding.isEmpty else { return "Almost done." }
        let list = outstanding.count <= 3
            ? outstanding.joined(separator: ", ")
            : outstanding.prefix(3).joined(separator: ", ")
              + " and \(outstanding.count - 3) more"
        return "Values from these records are not in yet: \(list)."
    }

    private var subtitle: String {
        guard let e = model.selected, let s = e.snapshot else { return "" }
        if e.isStillReading && e.isConnected { return "Reading…" }
        let drives = s.populatedBays.count
        return "\(drives) drives · \(Prefs.shared.capacity(s.freeBytes)) free"
    }
}
