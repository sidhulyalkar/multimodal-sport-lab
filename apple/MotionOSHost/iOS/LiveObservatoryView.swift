import Charts
import MotionOSAppleCapture
import SwiftUI

/// The Live Movement Observatory: a lossy real-time preview of the active
/// Watch recording. It renders exactly what `PhoneSessionCoordinator
/// .observation(at:)` resolves and never decides on its own whether data is
/// live. The sealed Watch journal remains the evidence.
struct LiveObservatoryView: View {
    enum Style {
        /// The Home tab hero, including the calm idle state.
        case hero
        /// Inside a capture workspace, where a session is already running.
        case embedded
    }

    var style: Style = .hero
    var onStartCapture: (() -> Void)?
    var onOpenDevices: (() -> Void)?

    @EnvironmentObject private var phone: PhoneSessionCoordinator

    private static let visibleWindow: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let observation = phone.observation(at: context.date)
            Group {
                if observation.observatory.isRecordingActive {
                    activeView(observation, now: context.date)
                } else if style == .hero {
                    idleView(observation)
                } else {
                    embeddedIdleView(observation)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: observation.observatory)
        }
    }

    // MARK: - Idle

    private func idleView(_ observation: WatchObservation) -> some View {
        let content = idleContent(observation)
        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(content.tint.opacity(0.10))
                    .frame(width: 76, height: 76)
                Image(systemName: content.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(content.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(content.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = content.action {
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.symbol)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .cardStyle(padding: 0)
    }

    private func embeddedIdleView(_ observation: WatchObservation) -> some View {
        let content = idleContent(observation)
        return HStack(spacing: 12) {
            Image(systemName: content.symbol)
                .foregroundStyle(content.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                Text(content.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private struct IdleAction {
        let title: String
        let symbol: String
        let perform: () -> Void
    }

    private struct IdleContent {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let action: IdleAction?
    }

    private func idleContent(_ observation: WatchObservation) -> IdleContent {
        let startAction = onStartCapture.map {
            IdleAction(title: "Start Session", symbol: "record.circle", perform: $0)
        }

        switch observation.observatory {
        case .checking:
            return IdleContent(
                title: "Checking your Watch",
                detail: observation.link.detail,
                symbol: "applewatch",
                tint: .secondary,
                action: nil
            )
        case .watchSetupRequired:
            if let startAction {
                return IdleContent(
                    title: "Choose a session to get started",
                    detail:
                        "MotionOS checks the devices required by the activity "
                            + "after you choose what you want to record.",
                    symbol: "figure.run.circle",
                    tint: .indigo,
                    action: startAction
                )
            }
            return IdleContent(
                title: observation.link.title,
                detail: observation.link.detail,
                symbol: observation.link.symbol,
                tint: .orange,
                action: onOpenDevices.map {
                    IdleAction(
                        title: "Fix Setup",
                        symbol: "applewatch",
                        perform: $0
                    )
                }
            )
        case .saved:
            return IdleContent(
                title: "Session saved",
                detail: "Your Watch recording is safely saved and will appear in Sessions when syncing finishes.",
                symbol: "checkmark.seal.fill",
                tint: .green,
                action: startAction
            )
        case .issue:
            return IdleContent(
                title: "Watch needs attention",
                detail: observation.link == .issue
                    ? observation.link.detail
                    : "The Watch stopped reporting. Open MotionOS on Apple Watch.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                action: nil
            )
        default:
            return IdleContent(
                title: "Ready when you are",
                detail: "Start a session and MotionOS will guide the setup for the activity you choose.",
                symbol: "waveform.path.ecg",
                tint: .indigo,
                action: startAction
            )
        }
    }

    // MARK: - Active

    private func activeView(
        _ observation: WatchObservation,
        now: Date
    ) -> some View {
        let phase = observation.observatory
        let frame = observation.sessionFrame
        let snapshot = frame?.snapshot

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                MotionOSStatusPill(
                    title: phase.badge,
                    tint: phase.tint,
                    pulsing: phase.isLive
                )
                Spacer(minLength: 8)
                Text(elapsedText(frame: frame, live: phase.isLive, now: now))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(phase.isLive ? .primary : .secondary)
                    .accessibilityLabel("Elapsed recording time")
            }

            if let message = statusMessage(phase) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            movementChart(observation, now: now)

            HStack(spacing: 10) {
                metric(
                    title: "Movement",
                    value: phase.isLive
                        ? snapshot?.motion.map { String(format: "%.2f", $0.userAccelerationPeakG) }
                        : nil,
                    unit: "g",
                    symbol: "figure.run",
                    tint: .indigo
                )
                metric(
                    title: "Heart",
                    value: phase.isLive
                        ? snapshot?.heartRateBPM.map { "\(Int($0.rounded()))" }
                        : nil,
                    unit: "bpm",
                    symbol: "heart.fill",
                    tint: .pink
                )
            }

            if let snapshot {
                Label(integrityText(snapshot), systemImage: integritySymbol(snapshot))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(integrityClean(snapshot) ? Color.secondary : Color.orange)
            }

            if style == .hero || snapshot != nil {
                DisclosureGroup("Technical details") {
                    signalDetails(snapshot)
                        .padding(.top, 8)
                }
                .font(.subheadline)
                .tint(.secondary)
            }
        }
        .cardStyle()
    }

    private func statusMessage(_ phase: LiveObservatoryPhase) -> String? {
        switch phase {
        case .starting:
            "Starting the Watch recording…"
        case .reconnecting:
            "Watch recording · Reconnecting live view…"
        case .paused:
            "Paused. The Watch keeps its recording open."
        case .finishing:
            "Sealing the Watch recording…"
        default:
            nil
        }
    }

    private func movementChart(
        _ observation: WatchObservation,
        now: Date
    ) -> some View {
        let live = observation.observatory.isLive
        let anchor = live ? now : (observation.sessionFrame?.receivedAt ?? now)
        let start = anchor.addingTimeInterval(-Self.visibleWindow)
        let points: [(Date, Double)] = observation.sessionFrame == nil
            ? []
            : phone.liveTelemetry.framesReceived(since: start).compactMap { frame in
                frame.snapshot.motion.map { (frame.receivedAt, $0.userAccelerationPeakG) }
            }
        let ceiling = max(0.5, (points.map(\.1).max() ?? 0) * 1.15)

        return ZStack {
            if points.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .overlay {
                        Text(
                            observation.observatory == .starting
                                ? "Waiting for the first movement…"
                                : "Waiting for live movement…"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
            } else {
                Chart {
                    ForEach(points, id: \.0) { point in
                        AreaMark(
                            x: .value("Time", point.0),
                            y: .value("Movement", point.1)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.indigo.opacity(0.30), Color.indigo.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Time", point.0),
                            y: .value("Movement", point.1)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(.init(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.indigo)
                    }
                }
                .chartXScale(domain: start...anchor)
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(String(format: "%.1f g", number))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .opacity(live ? 1 : 0.4)
                .saturation(live ? 1 : 0)
            }
        }
        .frame(height: style == .hero ? 190 : 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wrist movement over the last 30 seconds")
        .accessibilityValue(
            live
                ? (points.last.map { String(format: "%.2f g", $0.1) } ?? "No data")
                : "Not live"
        )
    }

    private func metric(
        title: String,
        value: String?,
        unit: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if value != nil {
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Details

    @ViewBuilder
    private func signalDetails(_ snapshot: LiveTelemetrySnapshot?) -> some View {
        let diagnostics = phone.liveTelemetry.diagnostics
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot {
                detailRow("Rotation", snapshot.motion.map {
                    String(format: "%.2f rad/s peak", $0.rotationRatePeakRadS)
                })
                detailRow("Orientation", orientationText(snapshot.motion))
                detailRow("IMU samples", "\(snapshot.imuSampleCount)")
                detailRow("Effective rate", snapshot.effectiveIMUHz.map {
                    String(format: "%.1f Hz", $0)
                })
                detailRow("Max gap", String(format: "%.0f ms", snapshot.maxIMUGapMS))
                detailRow("Timestamp reversals", "\(snapshot.nonMonotonicIMUCount)")
                detailRow("Watch battery", snapshot.watchBatteryFraction.map {
                    String(format: "%.0f%%", $0 * 100)
                })
            }
            detailRow(
                "Preview packets",
                "\(diagnostics.appended) shown · \(diagnostics.missingSequences) missed"
            )
            if diagnostics.duplicates + diagnostics.outOfOrder
                + diagnostics.invalidPackets + diagnostics.retiredSessionPackets > 0 {
                detailRow(
                    "Ignored packets",
                    "\(diagnostics.duplicates) dup · \(diagnostics.outOfOrder) late · "
                        + "\(diagnostics.retiredSessionPackets) old session · "
                        + "\(diagnostics.invalidPackets) invalid"
                )
            }
            Text("Live preview only. The saved Watch recording remains the source for later analysis.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func detailRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private func orientationText(_ motion: LiveTelemetrySnapshot.Motion?) -> String? {
        guard let roll = motion?.rollRadians,
              let pitch = motion?.pitchRadians,
              let yaw = motion?.yawRadians
        else {
            return nil
        }
        return String(
            format: "R %+.0f° P %+.0f° Y %+.0f°",
            roll * 180 / .pi,
            pitch * 180 / .pi,
            yaw * 180 / .pi
        )
    }

    // MARK: - Formatting

    private func elapsedText(
        frame: LiveTelemetryFrame?,
        live: Bool,
        now: Date
    ) -> String {
        guard let frame, let elapsed = frame.snapshot.elapsedSeconds else {
            return "--:--"
        }
        let running = elapsed + (live ? max(0, now.timeIntervalSince(frame.receivedAt)) : 0)
        let seconds = Int(running)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func integrityClean(_ snapshot: LiveTelemetrySnapshot) -> Bool {
        snapshot.nonMonotonicIMUCount == 0 && snapshot.maxIMUGapMS <= 100
    }

    private func integrityText(_ snapshot: LiveTelemetrySnapshot) -> String {
        let rate = snapshot.recentMedianIMUHz.map { String(format: "IMU %.1f Hz", $0) } ?? "IMU —"
        if snapshot.nonMonotonicIMUCount > 0 {
            return "\(rate) · \(snapshot.nonMonotonicIMUCount) timestamp reversals"
        }
        if snapshot.maxIMUGapMS > 100 {
            return "\(rate) · " + String(format: "gap up to %.0f ms", snapshot.maxIMUGapMS)
        }
        return "\(rate) · Stream clean"
    }

    private func integritySymbol(_ snapshot: LiveTelemetrySnapshot) -> String {
        integrityClean(snapshot) ? "checkmark.shield" : "exclamationmark.triangle"
    }
}
