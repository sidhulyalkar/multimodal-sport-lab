import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var controller: WatchSessionController
    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                brandHeader

                if isCaptureActive {
                    captureDashboard
                } else {
                    readinessCard
                    stateCard
                }

                if controller.captureRejections.total > 0 {
                    rejectionDiagnostics
                }

                if let error = controller.errorMessage {
                    errorCard(error)
                }

                buildFooter
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 8)
        }
        .confirmationDialog(
            "End this capture?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("End Capture", role: .destructive) {
                controller.stop()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("MotionOS will seal the Watch journal before transfer.")
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                statusColor.opacity(0.28),
                                Color.cyan.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Circle()
                    .stroke(statusColor.opacity(0.24), lineWidth: 1)
                    .frame(width: 36, height: 36)

                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MotionOS")
                    .font(.headline)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("READY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(readinessColor)
                    .frame(width: 7, height: 7)
            }

            readinessRow(
                title: "iPhone",
                value: controller.phoneLinkLabel,
                symbol: controller.phoneReachable
                    ? "iphone.radiowaves.left.and.right"
                    : "iphone",
                ready: controller.companionAppInstalled
                    || controller.phoneReachable
            )

            readinessRow(
                title: "Workout",
                value: controller.healthAuthorizationLabel,
                symbol: "heart.fill",
                ready: controller.healthAccessReady
            )

            if let battery = controller.watchBatteryLevel {
                readinessRow(
                    title: "Battery",
                    value: String(format: "%.0f%%", battery * 100),
                    symbol: battery >= 0.20
                        ? "battery.100percent"
                        : "battery.25percent",
                    ready: battery >= 0.20
                )
            }

            if !controller.healthAccessReady {
                Button {
                    Task { await controller.requestAuthorization() }
                } label: {
                    Label("Enable Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if controller.canStartCapture {
                Button {
                    Task { await controller.startLocalSensorCheck() }
                } label: {
                    Label("Run Sensor Check", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Text(
                controller.companionAppInstalled || controller.phoneReachable
                    ? "Ready for capture from the paired iPhone. Heart rate appears when read access is available."
                    : "Sensor Check can validate Watch capture while the iPhone link is being diagnosed."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }

    @ViewBuilder
    private var stateCard: some View {
        switch controller.state {
        case .idle:
            EmptyView()

        case .authorizing:
            progressPanel(
                title: "Authorizing Health",
                detail: "Complete the Health permission sheet on this Watch.",
                symbol: "heart.text.square"
            )

        case .starting:
            progressPanel(
                title: "Starting capture",
                detail: "Opening the workout, journal, and motion stream.",
                symbol: "waveform.path.ecg"
            )

        case .ending:
            progressPanel(
                title: "Sealing journal",
                detail: "Finishing accepted samples before the file closes.",
                symbol: "lock.doc"
            )

        case .journalReady:
            transferPanel(
                title: "Journal safe",
                detail: "The evidence file is sealed on this Watch.",
                symbol: "internaldrive.fill",
                action: "Retry Transfer"
            )

        case .transferQueued:
            progressPanel(
                title: "Transfer queued",
                detail: "The sealed journal remains safe locally.",
                symbol: "arrow.up.doc.fill"
            )

        case .transportComplete:
            transferPanel(
                title: "Sent to iPhone",
                detail: "Waiting for the iPhone to verify the file hash.",
                symbol: "iphone.and.arrow.forward",
                action: "Retry if needed"
            )

        case .transferred:
            VStack(alignment: .leading, spacing: 7) {
                Label("Verified on iPhone", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                if let sessionID = controller.sessionID {
                    Text(sessionID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .panelStyle()

        case .failed:
            EmptyView()

        case .running, .paused:
            EmptyView()
        }
    }

    private var captureDashboard: some View {
        VStack(spacing: 9) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 2) {
                    Text(
                        controller.startedAt.map {
                            duration(from: $0, to: context.date)
                        } ?? "00:00"
                    )
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(captureLiveColor(at: context.date))
                            .frame(width: 6, height: 6)
                        Text(captureLiveLabel(at: context.date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(captureLiveColor(at: context.date))

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(controller.captureOrigin.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            WatchMotionTrace(
                points: controller.visualTelemetryHistory,
                currentUserAccelerationG: controller.userAccelerationG,
                currentRotationRate: controller.rotationRateRadS
            )

            HStack(spacing: 6) {
                metricTile(
                    title: "HEART",
                    value: controller.heartRateBPM.map {
                        "\(Int($0.rounded()))"
                    } ?? "—",
                    unit: "BPM"
                )

                metricTile(
                    title: "IMU RATE",
                    value: controller.recentMedianIMUHz.map {
                        String(format: "%.1f", $0)
                    } ?? "—",
                    unit: "Hz"
                )
            }

            HStack(spacing: 6) {
                metricTile(
                    title: "SAMPLES",
                    value: "\(controller.imuSampleCount)",
                    unit: "IMU"
                )

                metricTile(
                    title: "MAX GAP",
                    value: String(format: "%.0f", controller.maxIMUGapMS),
                    unit: "ms"
                )
            }

            HStack(spacing: 6) {
                statusChip(
                    controller.phoneReachable ? "iPhone live" : "iPhone background",
                    symbol: controller.phoneReachable
                        ? "iphone.radiowaves.left.and.right"
                        : "iphone",
                    color: controller.phoneReachable ? .green : .secondary
                )

                if let battery = controller.watchBatteryLevel {
                    statusChip(
                        String(format: "%.0f%%", battery * 100),
                        symbol: battery >= 0.20
                            ? "battery.100percent"
                            : "battery.25percent",
                        color: battery >= 0.20 ? .secondary : .yellow
                    )
                }
            }

            if let cue = controller.guidedCueTitle {
                protocolCueCard(cue)
            }

            HStack(spacing: 7) {
                Button {
                    if controller.state == .running {
                        controller.pause()
                    } else {
                        controller.resume()
                    }
                } label: {
                    Image(
                        systemName: controller.state == .running
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    confirmStop = true
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .panelStyle()
    }

    private func protocolCueCard(
        _ title: String
    ) -> some View {
        let isSync = title == "SYNC · MOVE NOW"
        let detail = isSync
            ? "Sharp arm gesture now. Keep the board near neutral."
            : controller.productCueInstruction

        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(
                    systemName: isSync
                        ? "bolt.fill"
                        : "figure.surfing"
                )
                Text(isSync ? "SYNC" : "SESSION")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isSync ? .cyan : .secondary)

            Text(title)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let detail,
               !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            (isSync ? Color.cyan : Color.primary)
                .opacity(isSync ? 0.12 : 0.055),
            in: RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }

    private var rejectionDiagnostics: some View {
        let value = controller.captureRejections
        return VStack(alignment: .leading, spacing: 3) {
            Label("Capture diagnostics", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
            Text(
                "\(value.afterShutdown) late · "
                    + "\(value.sessionMismatch &+ value.noActiveSession) foreign · "
                    + "\(value.staleMotionGeneration) stale"
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Capture issue", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.hasRecoverableJournal {
                Button {
                    controller.retryTransfer()
                } label: {
                    Label("Transfer Saved Journal", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func progressPanel(
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(statusColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .panelStyle()
    }

    private func transferPanel(
        title: String,
        detail: String,
        symbol: String,
        action: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.yellow)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action) {
                controller.retryTransfer()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .panelStyle()
    }

    private func readinessRow(
        title: String,
        value: String,
        symbol: String,
        ready: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(ready ? .green : .secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ready ? .green : .secondary)
                .lineLimit(1)
        }
    }

    private func metricTile(
        title: String,
        value: String,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
    }

    private func statusChip(
        _ title: String,
        symbol: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }

    private var buildFooter: some View {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"

        return Text("MotionOS v\(version) · b\(build)")
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private var isCaptureActive: Bool {
        controller.state == .running || controller.state == .paused
    }

    private var statusText: String {
        switch controller.state {
        case .idle:
            controller.healthAccessReady ? "READY" : "SETUP"
        case .authorizing:
            "HEALTH"
        case .starting:
            "STARTING"
        case .running:
            "RECORDING"
        case .paused:
            "PAUSED"
        case .ending:
            "FINISHING"
        case .journalReady:
            "SAFE"
        case .transferQueued:
            "QUEUED"
        case .transportComplete:
            "VERIFYING"
        case .transferred:
            "VERIFIED"
        case .failed:
            "CHECK"
        }
    }

    private var statusSymbol: String {
        switch controller.state {
        case .running:
            "waveform.path.ecg"
        case .paused:
            "pause.fill"
        case .transferred:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .journalReady, .transferQueued, .transportComplete:
            "arrow.up.doc.fill"
        default:
            "figure.run"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running, .transferred:
            .green
        case .paused, .starting, .ending, .authorizing,
                .journalReady, .transferQueued, .transportComplete:
            .yellow
        case .failed:
            .red
        default:
            .secondary
        }
    }

    private var readinessColor: Color {
        controller.healthAccessReady
            && (controller.companionAppInstalled || controller.phoneReachable)
            ? .green
            : .yellow
    }

    private func captureLiveColor(at date: Date) -> Color {
        guard let last = controller.lastIMUSampleReceivedAt else {
            return .yellow
        }
        return date.timeIntervalSince(last) < 2 ? .green : .red
    }

    private func captureLiveLabel(at date: Date) -> String {
        guard let last = controller.lastIMUSampleReceivedAt else {
            return "WARMING UP"
        }
        let age = max(0, date.timeIntervalSince(last))
        return age < 2 ? "LIVE" : String(format: "STALE %.0fs", age)
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(10)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.085),
                        Color.white.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }
}
