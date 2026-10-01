import Charts
import MotionOSAppleCapture
import SwiftUI

struct SessionReviewCard: View {
    enum Signal: String, CaseIterable, Identifiable {
        case motion = "Motion"
        case heart = "Heart"

        var id: String { rawValue }
    }

    @EnvironmentObject private var inbox: PhoneJournalInbox
    @State private var signal: Signal = .motion

    var body: some View {
        if inbox.latestJournalURL != nil {
            VStack(alignment: .leading, spacing: 14) {
                header

                if inbox.reviewIsLoading {
                    loadingState
                } else if let summary = inbox.latestReview {
                    review(summary)
                } else if let error = inbox.latestReviewError {
                    errorState(error)
                } else {
                    Text("Waiting to derive the session review.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(
                    "Session Review is derived from the sealed Watch journal. "
                        + "It describes recorded signal behavior, not force, "
                        + "biomechanical quality, injury risk, or P0 qualification."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .cardStyle()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                    .frame(width: 38, height: 38)

                Image(systemName: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Session review")
                    .font(.headline)
                Text("A movement fingerprint from recovered raw evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("DERIVED")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.indigo)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.indigo.opacity(0.10), in: Capsule())
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading recovered Watch journal")
                    .font(.subheadline.weight(.semibold))
                Text("Analysis runs off the main UI thread.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorState(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }

    private func review(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionIdentity(summary)
            metricGrid(summary)

            Picker("Signal", selection: $signal) {
                ForEach(Signal.allCases) { signal in
                    Text(signal.rawValue).tag(signal)
                }
            }
            .pickerStyle(.segmented)

            switch signal {
            case .motion:
                motionChart(summary)
            case .heart:
                heartChart(summary)
            }

            fingerprint(summary)
            continuity(summary)
        }
    }

    private func sessionIdentity(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.sessionID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    identityChip(
                        summary.captureOrigin ?? "Unknown origin",
                        symbol: "applewatch"
                    )
                    if let wrist = summary.wristLocation {
                        identityChip(
                            "\(wrist.capitalized) wrist",
                            symbol: "hand.raised"
                        )
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    identityChip(
                        summary.captureOrigin ?? "Unknown origin",
                        symbol: "applewatch"
                    )
                    if let wrist = summary.wristLocation {
                        identityChip(
                            "\(wrist.capitalized) wrist",
                            symbol: "hand.raised"
                        )
                    }
                }
            }
        }
    }

    private func identityChip(
        _ text: String,
        symbol: String
    ) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: Capsule())
    }

    private func metricGrid(
        _ summary: WatchSessionSummary
    ) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 8,
            verticalSpacing: 8
        ) {
            GridRow {
                reviewMetric(
                    "DURATION",
                    duration(summary.durationSeconds),
                    symbol: "timer"
                )
                reviewMetric(
                    "IMU RATE",
                    String(format: "%.1f Hz", summary.effectiveIMUHz),
                    symbol: "waveform.path"
                )
            }
            GridRow {
                reviewMetric(
                    "MAX GAP",
                    String(
                        format: "%.0f ms",
                        summary.maxIMUMilliseconds
                    ),
                    symbol: "arrow.left.and.right"
                )
                reviewMetric(
                    "HEART",
                    summary.heartRateMedianBPM.map {
                        "\(Int($0.rounded())) median"
                    } ?? "No samples",
                    symbol: "heart.fill"
                )
            }
        }
    }

    private func reviewMetric(
        _ label: String,
        _ value: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func motionChart(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamic acceleration")
                        .font(.subheadline.weight(.semibold))
                    Text("1-second Watch buckets · Δg from 1 g")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if summary.motionTimeline.count >= 2 {
                Chart(summary.motionTimeline) { point in
                    AreaMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value("Peak Δg", point.peakMotionDeltaG)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.20),
                                Color.cyan.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value(
                            "Mean Δg",
                            point.meanMotionDeltaG
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.cyan)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round
                        )
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel {
                            if let value = $0.as(Double.self) {
                                Text(elapsedLabel(value))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 190)
            } else {
                emptyChart("Not enough motion samples to draw a timeline.")
            }

            HStack(spacing: 14) {
                legendDot("mean", color: .cyan)
                legendDot("1 s peak", color: .indigo)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color.cyan.opacity(0.08),
                    Color.indigo.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func heartChart(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heart-rate observations")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "HealthKit workout observations positioned by "
                        + "MotionOS callback-arrival time"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if summary.heartRateTimeline.count >= 2 {
                Chart(summary.heartRateTimeline) { point in
                    LineMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value("BPM", point.bpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.red)

                    PointMark(
                        x: .value("Time", point.elapsedSeconds),
                        y: .value("BPM", point.bpm)
                    )
                    .foregroundStyle(.red)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel {
                            if let value = $0.as(Double.self) {
                                Text(elapsedLabel(value))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 190)
            } else {
                emptyChart(
                    summary.heartRateTimeline.isEmpty
                        ? "No heart-rate samples were present."
                        : "One heart-rate sample was present."
                )
            }
        }
        .padding(12)
        .background(
            Color.red.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func fingerprint(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signal fingerprint")
                .font(.subheadline.weight(.semibold))

            signalRow(
                title: "Dynamic acceleration",
                median: summary.motionDeltaGMedian,
                p95: summary.motionDeltaGP95,
                unit: "Δg"
            )
            signalRow(
                title: "Angular rate",
                median: summary.rotationRateMedianRadS,
                p95: summary.rotationRateP95RadS,
                unit: "rad/s"
            )

            if summary.rollRangeDegrees != nil
                || summary.pitchRangeDegrees != nil
                || summary.yawRangeDegrees != nil {
                Divider()

                Text("Observed attitude range")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    rangeChip("Roll", summary.rollRangeDegrees)
                    rangeChip("Pitch", summary.pitchRangeDegrees)
                    rangeChip("Yaw", summary.yawRangeDegrees)
                }
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func signalRow(
        title: String,
        median: Double?,
        p95: Double?,
        unit: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text(
                median.map {
                    String(format: "median %.2f", $0)
                } ?? "median —"
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(
                p95.map {
                    String(format: "p95 %.2f %@", $0, unit)
                } ?? "p95 —"
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
        }
    }

    private func rangeChip(
        _ axis: String,
        _ value: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(axis.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(
                value.map {
                    String(format: "%.0f°", $0)
                } ?? "—"
            )
            .font(.caption.weight(.semibold))
            .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func continuity(
        _ summary: WatchSessionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    "Evidence continuity",
                    systemImage: summary.nonMonotonicIMUTimestamps == 0
                        && summary.missingIMUSequences == 0
                        ? "checkmark.shield.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    summary.nonMonotonicIMUTimestamps == 0
                        && summary.missingIMUSequences == 0
                        ? Color.green
                        : Color.yellow
                )
                Spacer()
            }

            Text(
                "\(summary.imuSampleCount) IMU samples · "
                    + "\(summary.heartRateEventCount) HR events"
            )
            .font(.system(.caption, design: .monospaced))

            Text(
                "\(summary.missingIMUSequences) missing sequence positions · "
                    + "\(summary.nonMonotonicIMUTimestamps) "
                    + "non-monotonic timestamps"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let median = summary.medianIMUMilliseconds {
                Text(
                    String(
                        format:
                            "Median IMU interval %.1f ms · max gap %.1f ms",
                        median,
                        summary.maxIMUMilliseconds
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func legendDot(
        _ text: String,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyChart(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 12)
            )
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

    private func elapsedLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%d:%02d",
            total / 60,
            total % 60
        )
    }
}
