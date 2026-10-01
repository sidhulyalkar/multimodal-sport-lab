import Charts
import SwiftUI

struct IndoBoardFramingCard: View {
    @EnvironmentObject private var camera: CameraCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Framing",
                subtitle: "Keep your full body, feet, and board inside the guide",
                systemImage: "viewfinder",
                accent: .cyan
            )

            ZStack {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .fill(Color.black)

                if camera.phase == .ready
                    || camera.phase == .recording
                    || camera.phase == .evidenceReady {
                    CameraPreviewView(
                        session: camera.previewSession
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 20,
                            style: .continuous
                        )
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.65))
                        Text("Prepare camera to preview framing")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height

                    RoundedRectangle(
                        cornerRadius: 28,
                        style: .continuous
                    )
                    .stroke(
                        Color.white.opacity(0.62),
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            dash: [7, 6]
                        )
                    )
                    .frame(
                        width: width * 0.55,
                        height: height * 0.78
                    )
                    .position(
                        x: width * 0.50,
                        y: height * 0.47
                    )

                    Capsule()
                        .fill(Color.cyan.opacity(0.78))
                        .frame(
                            width: width * 0.50,
                            height: 2
                        )
                        .position(
                            x: width * 0.50,
                            y: height * 0.83
                        )

                    Text("BOARD")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.cyan)
                        .position(
                            x: width * 0.50,
                            y: height * 0.87
                        )
                }
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        Spacer()
                        Text(cameraStatus)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                .black.opacity(0.55),
                                in: Capsule()
                            )
                    }
                    Spacer()
                }
                .padding(10)
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            if let stats = camera.liveStats {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        framingMetric(
                            "FPS",
                            stats.effectiveDeliveredFPS.map {
                                String(format: "%.1f", $0)
                            } ?? "—"
                        )
                        framingMetric(
                            "Written",
                            "\(stats.writtenFrames)"
                        )
                        framingMetric(
                            "Drops",
                            "\(stats.droppedFrames)"
                        )
                        framingMetric(
                            "Pose",
                            stats.poseSuccessFraction.map {
                                String(format: "%.0f%%", $0 * 100)
                            } ?? "—"
                        )
                    }

                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 8,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            framingMetric(
                                "FPS",
                                stats.effectiveDeliveredFPS.map {
                                    String(format: "%.1f", $0)
                                } ?? "—"
                            )
                            framingMetric(
                                "Drops",
                                "\(stats.droppedFrames)"
                            )
                        }
                        GridRow {
                            framingMetric(
                                "Written",
                                "\(stats.writtenFrames)"
                            )
                            framingMetric(
                                "Pose",
                                stats.poseSuccessFraction.map {
                                    String(format: "%.0f%%", $0 * 100)
                                } ?? "—"
                            )
                        }
                    }
                }
            }

            Text(
                "The guide is for operator framing only. It does not certify "
                    + "pose quality, calibration, or board geometry."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var cameraStatus: String {
        switch camera.phase {
        case .recording:
            "● RECORDING"
        case .ready:
            "READY"
        case .evidenceReady:
            "SEALED"
        case .authorizing:
            "AUTHORIZING"
        case .finalizing:
            "SEALING"
        case .denied:
            "DENIED"
        case .failed:
            "CHECK"
        case .idle:
            "OFF"
        }
    }

    private func framingMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }
}

struct IndoBoardLiveSignalCard: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var session: IndoBoardSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                MotionOSSectionHeader(
                    title: "Movement field",
                    subtitle: "Live Watch signal during this product session",
                    systemImage: "waveform.path.ecg",
                    accent: .indigo
                )

                Spacer(minLength: 6)

                TimelineView(.periodic(from: .now, by: 1)) { date in
                    let live = (phone.watchCaptureHealthAge(
                        at: date.date
                    ) ?? .infinity) <= 5
                    MotionOSStatusBadge(
                        title: live ? "LIVE" : "STALE",
                        systemImage: live
                            ? "dot.radiowaves.left.and.right"
                            : "clock",
                        color: live ? .green : .yellow
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    signalMetric(
                        "User accel",
                        phone.watchCaptureHealth?.userAccelerationG.map {
                            String(format: "%.2f g", $0)
                        } ?? "—",
                        "figure.run",
                        .indigo
                    )
                    signalMetric(
                        "Rotation",
                        phone.watchCaptureHealth?.rotationRateRadS.map {
                            String(format: "%.2f rad/s", $0)
                        } ?? "—",
                        "rotate.3d",
                        .purple
                    )
                    signalMetric(
                        "Heart",
                        phone.watchCaptureHealth?.heartRateBPM.map {
                            "\(Int($0.rounded())) bpm"
                        } ?? "—",
                        "heart.fill",
                        .pink
                    )
                }

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 8,
                    verticalSpacing: 8
                ) {
                    GridRow {
                        signalMetric(
                            "User accel",
                            phone.watchCaptureHealth?.userAccelerationG.map {
                                String(format: "%.2f g", $0)
                            } ?? "—",
                            "figure.run",
                            .indigo
                        )
                        signalMetric(
                            "Heart",
                            phone.watchCaptureHealth?.heartRateBPM.map {
                                "\(Int($0.rounded())) bpm"
                            } ?? "—",
                            "heart.fill",
                            .pink
                        )
                    }
                    GridRow {
                        signalMetric(
                            "Rotation",
                            phone.watchCaptureHealth?.rotationRateRadS.map {
                                String(format: "%.2f rad/s", $0)
                            } ?? "—",
                            "rotate.3d",
                            .purple
                        )
                    }
                }
            }

            if phone.watchTelemetryHistory.isEmpty {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(0.035))
                    Text("Waiting for live Watch telemetry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 130)
            } else {
                Chart(
                    Array(
                        phone.watchTelemetryHistory.suffix(60)
                    )
                ) { point in
                    if let value = point.userAccelerationG {
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Acceleration", value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.indigo.opacity(0.25),
                                    Color.cyan.opacity(0.015),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Acceleration", value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.indigo)
                        .lineStyle(
                            .init(
                                lineWidth: 2.2,
                                lineCap: .round
                            )
                        )
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(
                                .secondary.opacity(0.08)
                            )
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(String(format: "%.1f g", number))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 145)
            }

            HStack(spacing: 10) {
                orientationField
                VStack(alignment: .leading, spacing: 6) {
                    Text("WATCH ORIENTATION")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(attitudeText)
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()

                    Label(
                        continuityText,
                        systemImage: continuitySymbol
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(continuityColor)
                }
                Spacer(minLength: 0)
            }

            Text(
                "Live traces are operator feedback only. They are not a balance "
                    + "score and do not replace calibrated camera-rich metrics."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var orientationField: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let roll = phone.watchCaptureHealth?.rollRadians ?? 0
            let pitch = phone.watchCaptureHealth?.pitchRadians ?? 0

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.cyan.opacity(0.18),
                                Color.indigo.opacity(0.07),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 1,
                            endRadius: side * 0.55
                        )
                    )
                Circle()
                    .stroke(
                        Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(
                        width: side * 0.17,
                        height: side * 0.17
                    )
                    .offset(
                        x: CGFloat(sin(roll)) * side * 0.22,
                        y: CGFloat(sin(pitch)) * side * 0.22
                    )
            }
        }
        .frame(width: 72, height: 72)
        .accessibilityLabel("Apple Watch orientation field")
    }

    private func signalMetric(
        _ title: String,
        _ value: String,
        _ symbol: String,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(value)
                .font(
                    .system(
                        .subheadline,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(0.07),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    private var attitudeText: String {
        guard let health = phone.watchCaptureHealth,
              let roll = health.rollRadians,
              let pitch = health.pitchRadians,
              let yaw = health.yawRadians
        else {
            return "R —  P —  Y —"
        }

        return String(
            format: "R %+.0f°  P %+.0f°  Y %+.0f°",
            roll * 180 / .pi,
            pitch * 180 / .pi,
            yaw * 180 / .pi
        )
    }

    private var continuityText: String {
        guard let health = phone.watchCaptureHealth else {
            return "Waiting for timing"
        }
        if health.nonMonotonicIMUCount > 0 {
            return "\(health.nonMonotonicIMUCount) time reversals"
        }
        return String(
            format: "max gap %.0f ms",
            health.maxIMUGapMS
        )
    }

    private var continuitySymbol: String {
        guard let health = phone.watchCaptureHealth else {
            return "clock"
        }
        if health.nonMonotonicIMUCount > 0
            || health.maxIMUGapMS > 100 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.shield.fill"
    }

    private var continuityColor: Color {
        guard let health = phone.watchCaptureHealth else {
            return .secondary
        }
        if health.nonMonotonicIMUCount > 0
            || health.maxIMUGapMS > 100 {
            return .yellow
        }
        return .green
    }
}

struct IndoBoardProtocolRibbon: View {
    @EnvironmentObject private var fieldRun: FieldRunCoordinator
    @EnvironmentObject private var session: IndoBoardSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("SESSION TIMELINE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    "\(Int(min(120, session.elapsedSeconds))) / 120 s"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let elapsedFraction = min(
                    1,
                    session.elapsedSeconds
                        / IndoBoardSessionCoordinator
                            .targetDurationSeconds
                )

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(8, width * elapsedFraction),
                            height: 8
                        )

                    ForEach([0.125, 0.4375, 0.917], id: .self) {
                        marker in
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color(.systemBackground),
                                        lineWidth: 2
                                    )
                            }
                            .offset(
                                x: max(
                                    0,
                                    min(
                                        width - 9,
                                        width * marker - 4.5
                                    )
                                )
                            )
                    }
                }
            }
            .frame(height: 10)

            HStack {
                Text("settle")
                Spacer()
                Text("balance")
                Spacer()
                Text("recoveries")
                Spacer()
                Text("finish")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
        )
    }
}
