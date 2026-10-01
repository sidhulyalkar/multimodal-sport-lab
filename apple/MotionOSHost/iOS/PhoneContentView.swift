import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var coordinator: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    SensorSourceStrip()
                    LiveTelemetryDeck()
                    controls
                    readiness
                    GuidedP0Card()
                    FieldRunCard()
                    EquipmentPodCard()
                    CameraCaptureCard()
                    journalCard

                    if let error = coordinator.errorMessage ?? inbox.lastError {
                        errorCard(error)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack(alignment: .top) {
                    Color(.systemGroupedBackground)

                    LinearGradient(
                        colors: [
                            Color.indigo.opacity(0.13),
                            Color.cyan.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                    .frame(height: 420)
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MotionOSMark(size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MotionOS")
                        .font(.title2.weight(.bold))
                    Text("MOVEMENT OBSERVATORY")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    coordinator.refreshWatchState()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh device state")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("See the body in motion.")
                    .font(
                        .system(
                            .largeTitle,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                    .minimumScaleFactor(0.85)

                Text(
                    "Capture raw movement, watch signal quality live, "
                        + "and preserve every source for explicit calibration."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPill(
                        watchStatusLabel,
                        systemImage: watchStatusSymbol,
                        color: watchStatusColor
                    )
                    statusPill(
                        coordinator.state.rawValue.capitalized,
                        systemImage: stateSymbol,
                        color: stateColor
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    statusPill(
                        watchStatusLabel,
                        systemImage: watchStatusSymbol,
                        color: watchStatusColor
                    )
                    statusPill(
                        coordinator.state.rawValue.capitalized,
                        systemImage: stateSymbol,
                        color: stateColor
                    )
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "System readiness",
                subtitle: "Connection, power, and capture preflight",
                systemImage: "checklist.checked"
            )

            Divider()

            readinessRow(
                "Watch paired",
                value: coordinator.watchPaired,
                detail: coordinator.watchPaired ? "paired" : "missing"
            )
            readinessRow(
                "Watch app",
                value: coordinator.watchAppInstalled,
                detail: coordinator.hasRecentWatchPresence()
                    ? "handshake confirmed"
                    : (coordinator.watchAppInstalled ? "installed" : "not installed")
            )
            if let presence = coordinator.watchPresence {
                let current = coordinator.hasRecentWatchPresence()
                let age = coordinator.watchPresenceAge() ?? 0
                readinessRow(
                    "Watch handshake",
                    value: current,
                    detail: current
                        ? "v\(presence.appVersion) · b\(presence.appBuild)"
                        : String(format: "stale %.0fm", age / 60)
                )
            } else {
                readinessRow(
                    "Watch handshake",
                    value: false,
                    detail: "waiting"
                )
            }
            readinessRow(
                "Reachable now",
                value: coordinator.watchReachable,
                detail: coordinator.watchReachable ? "live link" : "background path only"
            )

            if coordinator.watchAppInstalled
                && !coordinator.systemWatchAppInstalled {
                Label(
                    "MotionOS handshake confirms the Watch app even though "
                        + "the system install flag is stale.",
                    systemImage: "applewatch.radiowaves.left.and.right"
                )
                .font(.caption2)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            } else if coordinator.watchPaired
                && !coordinator.watchAppInstalled {
                Label(
                    "Open MotionOS on the Watch to establish the companion "
                        + "handshake.",
                    systemImage: "applewatch"
                )
                .font(.caption2)
                .foregroundStyle(.yellow)
                .fixedSize(horizontal: false, vertical: true)
            }

            readinessRow(
                "iPhone battery",
                value: (coordinator.iPhoneBatteryLevel ?? 0) >= 0.20,
                detail: coordinator.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "unknown"
            )
            readinessRow(
                "Free storage",
                value: (coordinator.iPhoneAvailableStorageBytes ?? 0)
                    >= 5_000_000_000,
                detail: coordinator.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "unknown"
            )
            Text(
                "Development preflight warns below 20% battery or 5 GB free. "
                    + "These are operator safety margins, not qualification criteria."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack {
                Text("Workout state")
                Spacer()
                Text(coordinator.state.rawValue)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(stateColor)
            }

            if coordinator.state == .running
                || coordinator.state == .paused {
                watchHealthSummary
            }
        }
        .cardStyle()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Capture",
                subtitle: "Launch the next physical Watch session",
                systemImage: "record.circle"
            )

            Button {
                Task { await coordinator.startP0() }
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName:
                            "applewatch.radiowaves.left.and.right"
                    )
                    Text("Start Watch Capture")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                !coordinator.watchPaired
                    || !coordinator.watchAppInstalled
                    || coordinator.state == .launchingWatch
                    || coordinator.state == .waitingForMirror
                    || coordinator.state == .running
                    || coordinator.state == .paused
            )

            Button {
                Task { await coordinator.requestAuthorization() }
            } label: {
                Label(
                    "Authorize HealthKit",
                    systemImage: "heart.text.square"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text(
                "For first-light testing, stop from the Watch so journal "
                    + "sealing and transfer remain part of the exercised path."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var protocolCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("P0 field script", systemImage: "figure.walk.motion")
                .font(.headline)

            protocolRow("1", "30 s stationary baseline")
            protocolRow("2", "Rotate wrist around three axes")
            protocolRow("3", "Three deliberate sync impulses")
            protocolRow("4", "Walk for two minutes")
            protocolRow("5", "Lock/background the phone")
            protocolRow("6", "Temporarily separate phone and Watch")
            protocolRow("7", "Reconnect and stop from Watch")
            protocolRow("8", "Confirm journal arrives below")
        }
        .cardStyle()
    }

    private var journalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovered Watch journal", systemImage: "internaldrive")
                .font(.headline)

            if let sessionID = inbox.latestSessionID,
               let url = inbox.latestJournalURL {
                Text(sessionID)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "Hash-verified in iPhone Documents",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)

                if let hash = inbox.latestJournalSHA256,
                   let bytes = inbox.latestJournalByteCount {
                    Text(
                        "\(hash.prefix(12))… · "
                            + ByteCountFormatter.string(
                                fromByteCount: Int64(bytes),
                                countStyle: .file
                            )
                    )
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if let origin = inbox.latestCaptureOrigin {
                    Label(
                        "Capture origin: \(origin)",
                        systemImage: "applewatch"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if let diagnostics = inbox.latestTransferDiagnostics {
                    if diagnostics.total == 0 {
                        Label(
                            "Shutdown boundary clean",
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                "\(diagnostics.total) callbacks rejected at boundary",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.yellow)

                            Text(
                                "\(diagnostics.afterShutdown) late · "
                                    + "\(diagnostics.sessionMismatch &+ diagnostics.noActiveSession) foreign · "
                                    + "\(diagnostics.staleMotionGeneration) stale"
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if inbox.latestDuplicateRetransfer {
                    Label(
                        "Identical retry received; original evidence preserved",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if let hostURL = inbox.latestHostMetadataURL {
                    ShareLink(items: [url, hostURL]) {
                        Label(
                            "Share P0 evidence files",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                } else {
                    ShareLink(item: url) {
                        Label(
                            "Share raw journal",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            } else {
                Text("No journal received yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var watchHealthSummary: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let health = coordinator.watchCaptureHealth {
                let age = coordinator.watchCaptureHealthAge(
                    at: context.date
                ) ?? .infinity
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(
                            age <= 5
                                ? "Watch capture alive"
                                : "Watch telemetry stale",
                            systemImage: age <= 5
                                ? "waveform.path.ecg"
                                : "exclamationmark.triangle"
                        )
                        .foregroundStyle(age <= 5 ? .green : .yellow)

                        Spacer()

                        Text(
                            age <= 5
                                ? String(format: "%.0fs ago", age)
                                : String(format: "%.0fs stale", age)
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        metric(
                            "IMU",
                            health.recentMedianIMUHz.map {
                                String(format: "%.1f Hz", $0)
                            } ?? "warming up"
                        )
                        metric(
                            "gap",
                            String(
                                format: "%.0f ms",
                                health.maxIMUGapMS
                            )
                        )
                        metric(
                            "samples",
                            "\(health.imuSampleCount)"
                        )
                    }

                    if let battery = health.watchBatteryLevel {
                        HStack {
                            Image(
                                systemName: battery >= 0.20
                                    ? "battery.100percent"
                                    : "battery.25percent"
                            )
                            .foregroundStyle(
                                battery >= 0.20 ? .green : .yellow
                            )
                            Text(
                                String(
                                    format: "Watch battery %.0f%%",
                                    battery * 100
                                )
                            )
                            .font(.caption2)
                        }
                    }

                    Text(
                        "Live telemetry is operator feedback only; "
                            + "sealed Watch journal timestamps remain authoritative."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                Text(
                    coordinator.watchReachable
                        ? "Waiting for live Watch capture health…"
                        : "Watch live telemetry unavailable; background capture may still be valid."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readinessRow(_ title: String, value: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: value ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(value ? .green : .yellow)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func protocolRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.thinMaterial, in: Circle())
            Text(text)
                .font(.subheadline)
        }
    }

    private func sectionHeader(
        _ title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func statusPill(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.10), in: Capsule())
            .lineLimit(1)
    }

    private func errorCard(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.red.opacity(0.16), lineWidth: 1)
        }
    }

    private var watchStatusLabel: String {
        if coordinator.watchReachable {
            return "Watch live"
        }
        if coordinator.hasRecentWatchPresence() {
            return "Watch handshake"
        }
        if coordinator.watchAppInstalled {
            return "Watch installed"
        }
        return "Watch offline"
    }

    private var watchStatusSymbol: String {
        coordinator.watchAppInstalled
            ? "applewatch.radiowaves.left.and.right"
            : "applewatch"
    }

    private var watchStatusColor: Color {
        coordinator.watchAppInstalled ? .green : .yellow
    }

    private var stateSymbol: String {
        switch coordinator.state {
        case .running:
            "record.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .waitingForMirror, .launchingWatch, .authorizing:
            "clock.fill"
        case .failed, .disconnected:
            "exclamationmark.triangle.fill"
        default:
            "circle.fill"
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .running: .green
        case .paused, .waitingForMirror, .launchingWatch, .authorizing: .yellow
        case .failed, .disconnected: .red
        default: .secondary
        }
    }
}

private struct MotionOSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: 22,
                    style: .continuous
                )
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.92))
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 22,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(0.035),
                radius: 14,
                y: 7
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(MotionOSCardModifier())
    }
}
