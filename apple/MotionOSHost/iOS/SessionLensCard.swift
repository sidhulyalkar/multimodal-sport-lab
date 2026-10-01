import Charts
import SwiftUI

struct SessionLensCard: View {
    enum Signal: String, CaseIterable, Identifiable {
        case acceleration = "Acceleration"
        case rotation = "Rotation"

        var id: String { rawValue }
    }

    @EnvironmentObject private var inbox: PhoneJournalInbox
    @State private var signal: Signal = .acceleration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let summary = inbox.latestSessionSummary {
                summaryContent(summary)
            } else if let error = inbox.summaryError {
                unavailable(error)
            } else if inbox.latestSessionID != nil {
                deriving
            } else {
                empty
            }
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.18),
                                Color.cyan.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)

                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Session lens")
                    .font(.headline)
                Text("Derived view of the latest sealed Watch journal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if inbox.latestSessionSummary != nil {
                Label("SEALED", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.10), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func summaryContent(
        _ summary: WatchSessionSummary
    ) -> some View {
        overview(summary)

        Picker("Session signal", selection: $signal) {
            ForEach(Signal.allCases) { signal in
                Text(signal.rawValue).tag(signal)
            }
        }
        .pickerStyle(.segmented)

        sessionChart(summary)

        motionStats(summary)
        integrity(summary)
        provenance(summary)

        Text(summary.claimBoundary)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func overview(
        _ summary: WatchSessionSummary
    ) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 8,
            verticalSpacing: 8
        ) {
            GridRow {
                summaryMetric(
                    label: "DURATION",
                    value: duration(summary.imu.durationSeconds),
                    detail: "captured",
                    symbol: "timer",
                    accent: .indigo
                )

                summaryMetric(
                    label: "IMU RATE",
                    value: String(
                        format: "%.1f Hz",
                        summary.imu.effectiveHz
                    ),
                    detail: "\(summary.imu.count) samples",
                    symbol: "waveform.path",
                    accent: .cyan
                )
            }

            GridRow {
                summaryMetric(
                    label: "MOTION RMS",
                    value: summary.motion.userAccelerationRMSG.map {
                        String(format: "%.2f g", $0)
                    } ?? "—",
                    detail: "user acceleration",
                    symbol: "figure.run",
                    accent: .purple
                )

                summaryMetric(
                    label: "HEART",
                    value: summary.heartRate.meanBPM.map {
                        "\(Int($0.rounded())) BPM"
                    } ?? "—",
                    detail: summary.heartRate.count > 0
                        ? "\(summary.heartRate.count) samples"
                        : "not observed",
                    symbol: "heart.fill",
                    accent: .pink
                )
            }
        }
    }

    @ViewBuilder
    private func sessionChart(
        _ summary: WatchSessionSummary
    ) -> some View {
        if summary.trace.isEmpty {
            chartPlaceholder
        } else {
            switch signal {
            case .acceleration:
                Chart(summary.trace, id: \.elapsedSeconds) { point in
                    AreaMark(
                        x: .value("Elapsed", point.elapsedSeconds),
                        y: .value(
                            "Mean user acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.28),
                                Color.indigo.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Elapsed", point.elapsedSeconds),
                        y: .value(
                            "Mean user acceleration",
                            point.meanUserAccelerationG
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .foregroundStyle(.indigo)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.08))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(shortDuration(seconds))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.10))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(String(format: "%.1f g", number))
                            }
                        }
                    }
                }
                .frame(height: 170)
                .accessibilityLabel(
                    "Mean user acceleration across the sealed Watch session"
                )

            case .rotation:
                Chart(summary.trace, id: \.elapsedSeconds) { point in
                    AreaMark(
                        x: .value("Elapsed", point.elapsedSeconds),
                        y: .value(
                            "Mean rotation",
                            point.meanRotationRateRadS
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.28),
                                Color.cyan.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Elapsed", point.elapsedSeconds),
                        y: .value(
                            "Mean rotation",
                            point.meanRotationRateRadS
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .foregroundStyle(.cyan)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.08))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(shortDuration(seconds))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.10))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(String(format: "%.1f", number))
                            }
                        }
                    }
                }
                .frame(height: 170)
                .accessibilityLabel(
                    "Mean angular-rate magnitude across the sealed Watch session"
                )
            }
        }
    }

    private func motionStats(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSION DISTRIBUTION")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statChip(
                        title: "Accel p95",
                        value: summary.motion.userAccelerationP95G.map {
                            String(format: "%.2f g", $0)
                        } ?? "—"
                    )
                    statChip(
                        title: "Rotation RMS",
                        value: summary.motion.rotationRateRMSRadS.map {
                            String(format: "%.2f rad/s", $0)
                        } ?? "—"
                    )
                    statChip(
                        title: "Rotation p95",
                        value: summary.motion.rotationRateP95RadS.map {
                            String(format: "%.2f rad/s", $0)
                        } ?? "—"
                    )
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        statChip(
                            title: "Accel p95",
                            value: summary.motion.userAccelerationP95G.map {
                                String(format: "%.2f g", $0)
                            } ?? "—"
                        )
                        statChip(
                            title: "Rotation RMS",
                            value: summary.motion.rotationRateRMSRadS.map {
                                String(format: "%.2f rad/s", $0)
                            } ?? "—"
                        )
                    }
                    statChip(
                        title: "Rotation p95",
                        value: summary.motion.rotationRateP95RadS.map {
                            String(format: "%.2f rad/s", $0)
                        } ?? "—"
                    )
                }
            }

            if let min = summary.heartRate.minimumBPM,
               let mean = summary.heartRate.meanBPM,
               let max = summary.heartRate.maximumBPM {
                Text(
                    "Heart range "
                        + "\(Int(min.rounded()))–\(Int(max.rounded())) BPM "
                        + "· mean \(Int(mean.rounded())) BPM"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func integrity(
        _ summary: WatchSessionSummary
    ) -> some View {
        let clean = summary.imu.missingSequences == 0
            && summary.imu.nonMonotonicSequences == 0
            && summary.imu.nonMonotonicTimestamps == 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    clean ? "Stream continuity clean" : "Review continuity",
                    systemImage: clean
                        ? "checkmark.shield.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(clean ? Color.green : Color.yellow)

                Spacer(minLength: 8)

                Text(
                    String(
                        format: "max gap %.0f ms",
                        summary.imu.maxGapMS
                    )
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                integrityValue(
                    "missing",
                    summary.imu.missingSequences
                )
                integrityValue(
                    "sequence reversals",
                    summary.imu.nonMonotonicSequences
                )
                integrityValue(
                    "time reversals",
                    summary.imu.nonMonotonicTimestamps
                )
            }
        }
        .padding(12)
        .background(
            (clean ? Color.green : Color.yellow).opacity(0.055),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func provenance(
        _ summary: WatchSessionSummary
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "number.square.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.sessionID)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                Text(
                    "source \(summary.sourceJournalSHA256.prefix(12))…"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let url = inbox.latestSessionSummaryURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share derived Watch session summary")
            }
        }
    }

    private var deriving: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Building the session lens")
                    .font(.subheadline.weight(.semibold))
                Text("Streaming the sealed journal into bounded derived metrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No sealed Watch session yet")
                    .font(.subheadline.weight(.semibold))
                Text("Your first recovered journal will appear here as a trace and integrity summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func unavailable(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .padding(.vertical, 4)
    }

    private var chartPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
            Label("No motion trace available", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 150)
    }

    private func summaryMetric(
        label: String,
        value: String,
        detail: String,
        symbol: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)

            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.10),
                    Color.primary.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func statChip(
        title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func integrityValue(
        _ label: String,
        _ value: UInt64
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3600,
                (total % 3600) / 60,
                total % 60
            )
        }
        return String(
            format: "%02d:%02d",
            total / 60,
            total % 60
        )
    }

    private func shortDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 60 {
            return "\(value / 60)m"
        }
        return "\(value)s"
    }
}
