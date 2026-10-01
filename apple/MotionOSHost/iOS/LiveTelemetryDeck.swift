import Charts
import SwiftUI

struct LiveTelemetryDeck: View {
    enum Signal: String, CaseIterable, Identifiable {
        case motion = "Motion"
        case heart = "Heart"
        case timing = "Timing"

        var id: String { rawValue }
    }

    @EnvironmentObject private var coordinator: PhoneSessionCoordinator
    @State private var signal: Signal = .motion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metricGrid
            signalPicker
            chart
            attitudeAndIntegrity

            Text(
                "Live views are derived operator telemetry. "
                    + "Raw Watch channels and the sealed journal remain authoritative."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.25),
                                Color.indigo.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)

                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(
                        coordinator.state == .running
                            ? Color.green
                            : Color.cyan
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Live observatory")
                    .font(.headline)
                Text(liveSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                freshnessBadge(at: context.date)
            }
        }
    }

    private var metricGrid: some View {
        let health = coordinator.watchCaptureHealth

        return Grid(
            alignment: .leading,
            horizontalSpacing: 8,
            verticalSpacing: 8
        ) {
            GridRow {
                metricTile(
                    label: "IMU RATE",
                    value: health?.recentMedianIMUHz.map {
                        String(format: "%.1f", $0)
                    } ?? "—",
                    unit: "Hz",
                    symbol: "waveform.path",
                    accent: .cyan
                )

                metricTile(
                    label: "HEART",
                    value: health?.heartRateBPM.map {
                        "\(Int($0.rounded()))"
                    } ?? "—",
                    unit: "BPM",
                    symbol: "heart.fill",
                    accent: .pink
                )
            }

            GridRow {
                metricTile(
                    label: "DYNAMIC",
                    value: health?.motionDeltaG.map {
                        String(format: "%.2f", $0)
                    } ?? "—",
                    unit: "Δg",
                    symbol: "figure.run",
                    accent: .indigo
                )

                metricTile(
                    label: "ROTATION",
                    value: health?.rotationRateRadS.map {
                        String(format: "%.2f", $0)
                    } ?? "—",
                    unit: "rad/s",
                    symbol: "rotate.3d",
                    accent: .purple
                )
            }
        }
    }

    private var signalPicker: some View {
        Picker("Signal", selection: $signal) {
            ForEach(Signal.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Live signal visualization")
    }

    @ViewBuilder
    private var chart: some View {
        if coordinator.watchTelemetryHistory.isEmpty {
            emptyChart
        } else {
            switch signal {
            case .motion:
                motionChart
            case .heart:
                heartChart
            case .timing:
                timingChart
            }
        }
    }

    private var motionChart: some View {
        let points = coordinator.watchTelemetryHistory.filter {
            $0.motionDeltaG != nil
        }

        return Chart(points) { point in
            if let value = point.motionDeltaG {
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Dynamic acceleration", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.indigo.opacity(0.28),
                            Color.cyan.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Dynamic acceleration", value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(.init(lineWidth: 2.3, lineCap: .round))
                .foregroundStyle(Color.indigo)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(String(format: "%.1f", number))
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Dynamic acceleration history")
    }

    private var heartChart: some View {
        let points = coordinator.watchTelemetryHistory.filter {
            $0.heartRateBPM != nil
        }

        return Group {
            if points.isEmpty {
                chartPlaceholder(
                    title: "Waiting for heart-rate samples",
                    symbol: "heart"
                )
            } else {
                Chart(points) { point in
                    if let value = point.heartRateBPM {
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Heart rate", value)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 2.3, lineCap: .round))
                        .foregroundStyle(Color.pink)

                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Heart rate", value)
                        )
                        .symbolSize(12)
                        .foregroundStyle(Color.pink.opacity(0.55))
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Heart rate history")
            }
        }
    }

    private var timingChart: some View {
        let points = coordinator.watchTelemetryHistory.filter {
            $0.imuHz != nil
        }

        return Chart {
            ForEach(points) { point in
                if let value = point.imuHz {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("IMU rate", value)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(.init(lineWidth: 2.3, lineCap: .round))
                    .foregroundStyle(Color.cyan)
                }
            }

            RuleMark(y: .value("Requested", 50.0))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary.opacity(0.45))
                .annotation(position: .top, alignment: .trailing) {
                    Text("50 Hz target")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel()
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Watch IMU sample rate history")
    }

    private var emptyChart: some View {
        chartPlaceholder(
            title: "Start a Sensor Check to light up the signal",
            symbol: "waveform"
        )
    }

    private func chartPlaceholder(
        title: String,
        symbol: String
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))

            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(height: 150)
    }

    private var attitudeAndIntegrity: some View {
        HStack(spacing: 10) {
            DeviceAttitudeOrb(
                roll: coordinator.watchCaptureHealth?.rollRadians,
                pitch: coordinator.watchCaptureHealth?.pitchRadians
            )

            VStack(alignment: .leading, spacing: 7) {
                Text("DEVICE ATTITUDE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(attitudeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)

                Label(
                    continuityLabel,
                    systemImage: continuitySymbol
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(continuityColor)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func metricTile(
        label: String,
        value: String,
        unit: String,
        symbol: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(accent)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)

                Text(unit)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.11),
                    Color.primary.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private func freshnessBadge(at date: Date) -> some View {
        let age = coordinator.watchCaptureHealthAge(at: date) ?? .infinity
        let live = age <= 5

        Label(
            live ? "LIVE" : "STANDBY",
            systemImage: live ? "dot.radiowaves.left.and.right" : "circle.dotted"
        )
        .font(.caption2.weight(.bold))
        .foregroundStyle(live ? Color.green : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            (live ? Color.green : Color.secondary).opacity(0.10),
            in: Capsule()
        )
    }

    private var liveSubtitle: String {
        if coordinator.state == .running {
            return "Watch motion, physiology, timing, and device attitude"
        }
        if !coordinator.watchTelemetryHistory.isEmpty {
            return "Latest live operator telemetry from this session"
        }
        return "A real-time window into the Watch capture substrate"
    }

    private var attitudeText: String {
        guard let health = coordinator.watchCaptureHealth,
              let roll = health.rollRadians,
              let pitch = health.pitchRadians,
              let yaw = health.yawRadians
        else {
            return "roll —  pitch —  yaw —"
        }

        return String(
            format: "R %+.0f°  P %+.0f°  Y %+.0f°",
            roll * 180 / .pi,
            pitch * 180 / .pi,
            yaw * 180 / .pi
        )
    }

    private var continuityLabel: String {
        guard let health = coordinator.watchCaptureHealth else {
            return "Waiting for continuity data"
        }
        if health.nonMonotonicIMUCount > 0 {
            return "\(health.nonMonotonicIMUCount) timestamp reversals"
        }
        if health.maxIMUGapMS > 100 {
            return String(format: "Largest gap %.0f ms", health.maxIMUGapMS)
        }
        return "Monotonic stream · max gap "
            + String(format: "%.0f ms", health.maxIMUGapMS)
    }

    private var continuitySymbol: String {
        guard let health = coordinator.watchCaptureHealth else {
            return "clock"
        }
        return health.nonMonotonicIMUCount == 0
            ? "checkmark.shield.fill"
            : "exclamationmark.triangle.fill"
    }

    private var continuityColor: Color {
        guard let health = coordinator.watchCaptureHealth else {
            return .secondary
        }
        return health.nonMonotonicIMUCount == 0 ? .green : .red
    }
}

private struct DeviceAttitudeOrb: View {
    let roll: Double?
    let pitch: Double?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let x = CGFloat(sin(roll ?? 0)) * side * 0.20
            let y = CGFloat(sin(pitch ?? 0)) * side * 0.20

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.cyan.opacity(0.20),
                                Color.indigo.opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: side * 0.55
                        )
                    )

                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: side * 0.18, height: side * 0.18)
                    .shadow(color: .cyan.opacity(0.35), radius: 5)
                    .offset(x: x, y: y)
            }
        }
        .frame(width: 72, height: 72)
        .accessibilityLabel("Device attitude indicator")
    }
}
