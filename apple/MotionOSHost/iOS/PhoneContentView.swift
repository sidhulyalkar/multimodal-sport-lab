import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var coordinator: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    readiness
                    controls
                    FieldRunCard()
                    GuidedP0Card()
                    journalCard
                    EquipmentPodCard()
                    CameraCaptureCard()

                    if let error = coordinator.errorMessage ?? inbox.lastError {
                        errorCard(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack(alignment: .top) {
                    Color(.systemGroupedBackground)
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.11),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                MotionOSMark(size: 50)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MotionOS")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("M0-B  •  PHYSICAL CAPTURE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    coordinator.refreshWatchState()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh device state")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Capture lab")
                    .font(.system(.title, design: .rounded, weight: .bold))

                Text(
                    "Keep Watch, equipment, and camera evidence synchronized without rewriting their native clocks. Raw first, calibrate explicitly."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPill(
                        readinessLabel,
                        systemImage: readinessCount == readinessTotal
                            ? "checkmark.circle.fill"
                            : "circle.dotted",
                        color: readinessCount == readinessTotal ? .green : .orange
                    )
                    statusPill(
                        coordinator.state.rawValue,
                        systemImage: stateSymbol,
                        color: stateColor
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    statusPill(
                        readinessLabel,
                        systemImage: readinessCount == readinessTotal
                            ? "checkmark.circle.fill"
                            : "circle.dotted",
                        color: readinessCount == readinessTotal ? .green : .orange
                    )
                    statusPill(
                        coordinator.state.rawValue,
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
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader(
                "Readiness",
                subtitle: "Live preflight state",
                systemImage: "checklist.checked"
            )

            Divider()

            readinessRow(
                "Watch paired",
                value: coordinator.watchPaired,
                detail: coordinator.watchPaired ? "Paired" : "Missing"
            )
            readinessRow(
                "Watch app",
                value: coordinator.watchAppInstalled,
                detail: coordinator.watchAppInstalled ? "Installed" : "Not installed"
            )
            readinessRow(
                "Reachable now",
                value: coordinator.watchReachable,
                detail: coordinator.watchReachable ? "Live link" : "Background path"
            )
            readinessRow(
                "iPhone battery",
                value: (coordinator.iPhoneBatteryLevel ?? 0) >= 0.20,
                detail: coordinator.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "Unknown"
            )
            readinessRow(
                "Free storage",
                value: (coordinator.iPhoneAvailableStorageBytes ?? 0) >= 5_000_000_000,
                detail: coordinator.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "Unknown"
            )

            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(stateColor)
                Text("Workout state")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(coordinator.state.rawValue.capitalized)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(stateColor.opacity(0.11), in: Capsule())
            }
            .padding(.top, 2)

            if coordinator.state == .running || coordinator.state == .paused {
                Divider()
                watchHealthSummary
            }

            Text(
                "Development preflight warns below 20% battery or 5 GB free. These are operator safety margins, not qualification criteria."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader(
                "Capture controls",
                subtitle: "Start the physical qualification path",
                systemImage: "record.circle"
            )

            Button {
                Task { await coordinator.startP0() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                    Text("Start P0 on Apple Watch")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                coordinator.state == .launchingWatch
                    || coordinator.state == .waitingForMirror
                    || coordinator.state == .running
                    || coordinator.state == .paused
            )

            Button {
                Task { await coordinator.requestAuthorization() }
            } label: {
                Label("Authorize HealthKit", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text(
                "End the first qualification session from the Watch. Phone-side stop control comes after P0 proves mirroring and journal recovery."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var journalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Recovered Watch journal",
                subtitle: inbox.latestSessionID == nil ? "Waiting for first evidence bundle" : "Latest verified evidence",
                systemImage: "internaldrive"
            )

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
                .font(.caption.weight(.medium))
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
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No journal received yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
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

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label(
                            age <= 5
                                ? "Watch capture alive"
                                : "Watch telemetry stale",
                            systemImage: age <= 5
                                ? "waveform.path.ecg"
                                : "exclamationmark.triangle"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(age <= 5 ? .green : .yellow)

                        Spacer(minLength: 8)

                        Text(
                            age <= 5
                                ? String(format: "%.0fs ago", age)
                                : String(format: "%.0fs stale", age)
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            metric(
                                "IMU",
                                health.recentMedianIMUHz.map {
                                    String(format: "%.1f Hz", $0)
                                } ?? "Warming up"
                            )
                            metric(
                                "Gap",
                                String(format: "%.0f ms", health.maxIMUGapMS)
                            )
                            metric("Samples", "\(health.imuSampleCount)")
                        }

                        VStack(spacing: 8) {
                            metric(
                                "IMU",
                                health.recentMedianIMUHz.map {
                                    String(format: "%.1f Hz", $0)
                                } ?? "Warming up"
                            )
                            metric(
                                "Gap",
                                String(format: "%.0f ms", health.maxIMUGapMS)
                            )
                            metric("Samples", "\(health.imuSampleCount)")
                        }
                    }

                    if let battery = health.watchBatteryLevel {
                        HStack(spacing: 7) {
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
                        "Live telemetry is operator feedback only; sealed Watch journal timestamps remain authoritative."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
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

    private func sectionHeader(
        _ title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

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

    private func readinessRow(
        _ title: String,
        value: Bool,
        detail: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                readinessIcon(value)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    readinessIcon(value)
                    Text(title)
                        .font(.subheadline)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
        }
    }

    private func readinessIcon(_ value: Bool) -> some View {
        Image(
            systemName: value
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill"
        )
        .foregroundStyle(value ? .green : .yellow)
        .font(.body.weight(.semibold))
        .frame(width: 22)
    }

    private func metric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
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
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.red.opacity(0.18), lineWidth: 1)
        }
    }

    private var readinessCount: Int {
        [
            coordinator.watchPaired,
            coordinator.watchAppInstalled,
            coordinator.watchReachable,
            (coordinator.iPhoneBatteryLevel ?? 0) >= 0.20,
            (coordinator.iPhoneAvailableStorageBytes ?? 0) >= 5_000_000_000
        ]
        .filter { $0 }
        .count
    }

    private var readinessTotal: Int { 5 }

    private var readinessLabel: String {
        "\(readinessCount)/\(readinessTotal) ready"
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
        case .running:
            .green
        case .paused, .waitingForMirror, .launchingWatch, .authorizing:
            .yellow
        case .failed, .disconnected:
            .red
        default:
            .secondary
        }
    }
}

private struct MotionOSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(MotionOSCardModifier())
    }
}
