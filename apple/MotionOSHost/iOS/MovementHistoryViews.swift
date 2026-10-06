import Charts
import MotionOSAppleCapture
import SwiftUI

struct MovementTrendsCard: View {
    enum Metric: String, CaseIterable, Identifiable {
        case acceleration = "Acceleration"
        case rotation = "Rotation"
        case heart = "Heart"

        var id: String { rawValue }
    }

    @EnvironmentObject private var library: ProductRunLibrary
    @State private var metric: Metric = .acceleration

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    var body: some View {
        let points = trendPoints

        return VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Watch signal history",
                subtitle: historySubtitle,
                systemImage: "chart.xyaxis.line",
                accent: .purple
            )

            Picker("Watch signal history metric", selection: $metric) {
                ForEach(Metric.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Session", point.date),
                        y: .value(metricAxisTitle, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(
                        .init(
                            lineWidth: 2.4,
                            lineCap: .round
                        )
                    )
                    .foregroundStyle(metricColor)

                    PointMark(
                        x: .value("Session", point.date),
                        y: .value(metricAxisTitle, point.value)
                    )
                    .symbolSize(34)
                    .foregroundStyle(metricColor)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        value in
                        AxisGridLine()
                            .foregroundStyle(
                                .secondary.opacity(0.07)
                            )
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(
                                    date.formatted(
                                        .dateTime
                                            .month(.abbreviated)
                                            .day()
                                    )
                                )
                                .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)

                if let first = points.first,
                   let last = points.last {
                    HStack(spacing: 8) {
                        historyMetric(
                            "FIRST",
                            formatted(first.value)
                        )
                        historyMetric(
                            "LATEST",
                            formatted(last.value)
                        )
                        historyMetric(
                            "DIFFERENCE",
                            signedDelta(
                                latest: last.value,
                                previous: first.value
                            )
                        )
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    Text("Two sessions unlock signal history")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "This chart shows descriptive Watch signals across "
                            + "completed Indo Board sessions. Personal ranges "
                            + "use the stricter reviewed comparison pipeline."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Text(
                "This legacy signal history is not context-matched and is not "
                    + "the personal movement baseline. Differences can reflect task "
                    + "intensity, Watch placement, fatigue, or setup changes."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var trendPoints: [Point] {
        library.runs
            .compactMap { run -> Point? in
                guard run.protocolKind
                        == FieldProtocolKind.indoBoard.rawValue,
                      run.outcome == .completed,
                      let date = run.startedAt ?? run.sealedAt,
                      let summary = run.watchSummary,
                      let value = metricValue(summary)
                else {
                    return nil
                }
                return Point(
                    id: run.id,
                    date: date,
                    value: value
                )
            }
            .sorted { $0.date < $1.date }
    }

    private var historySubtitle: String {
        switch metric {
        case .acceleration:
            "Watch user-acceleration RMS across sealed Indo Board runs"
        case .rotation:
            "Watch angular-rate RMS across sealed Indo Board runs"
        case .heart:
            "Mean recorded heart rate across sealed Indo Board runs"
        }
    }

    private var metricAxisTitle: String {
        switch metric {
        case .acceleration:
            "Acceleration (g)"
        case .rotation:
            "Rotation (rad/s)"
        case .heart:
            "Heart rate (bpm)"
        }
    }

    private var metricColor: Color {
        switch metric {
        case .acceleration:
            .indigo
        case .rotation:
            .purple
        case .heart:
            .pink
        }
    }

    private func metricValue(
        _ summary: WatchSessionSummary
    ) -> Double? {
        switch metric {
        case .acceleration:
            summary.motion.userAccelerationRMSG
        case .rotation:
            summary.motion.rotationRateRMSRadS
        case .heart:
            summary.heartRate.meanBPM
        }
    }

    private func formatted(
        _ value: Double
    ) -> String {
        switch metric {
        case .acceleration:
            String(format: "%.2f g", value)
        case .rotation:
            String(format: "%.2f rad/s", value)
        case .heart:
            String(format: "%.0f bpm", value)
        }
    }

    private func signedDelta(
        latest: Double,
        previous: Double
    ) -> String {
        let delta = latest - previous
        switch metric {
        case .acceleration:
            return String(format: "%+.2f g", delta)
        case .rotation:
            return String(format: "%+.2f", delta)
        case .heart:
            return String(format: "%+.0f bpm", delta)
        }
    }

    private func historyMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
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
                .minimumScaleFactor(0.72)
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

struct PreviousRunComparisonCard: View {
    let run: ProductRunRecord

    @EnvironmentObject private var library: ProductRunLibrary

    var body: some View {
        if run.outcome == .completed,
           let previous = previousComparableRun,
           let currentSummary = run.watchSummary,
           let previousSummary = previous.watchSummary {
            VStack(alignment: .leading, spacing: 12) {
                MotionOSSectionHeader(
                    title: "Compared with previous session",
                    subtitle: comparisonSubtitle(previous),
                    systemImage: "arrow.left.arrow.right",
                    accent: .cyan
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        deltaTile(
                            "Accel RMS",
                            delta(
                                currentSummary.motion
                                    .userAccelerationRMSG,
                                previousSummary.motion
                                    .userAccelerationRMSG
                            ),
                            unit: "g"
                        )
                        deltaTile(
                            "Rotation RMS",
                            delta(
                                currentSummary.motion
                                    .rotationRateRMSRadS,
                                previousSummary.motion
                                    .rotationRateRMSRadS
                            ),
                            unit: "rad/s"
                        )
                        deltaTile(
                            "Mean HR",
                            delta(
                                currentSummary.heartRate.meanBPM,
                                previousSummary.heartRate.meanBPM
                            ),
                            unit: "bpm",
                            decimals: 0
                        )
                    }

                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            deltaTile(
                                "Accel RMS",
                                delta(
                                    currentSummary.motion
                                        .userAccelerationRMSG,
                                    previousSummary.motion
                                        .userAccelerationRMSG
                                ),
                                unit: "g"
                            )
                            deltaTile(
                                "Rotation RMS",
                                delta(
                                    currentSummary.motion
                                        .rotationRateRMSRadS,
                                    previousSummary.motion
                                        .rotationRateRMSRadS
                                ),
                                unit: "rad/s"
                            )
                        }
                        deltaTile(
                            "Mean HR",
                            delta(
                                currentSummary.heartRate.meanBPM,
                                previousSummary.heartRate.meanBPM
                            ),
                            unit: "bpm",
                            decimals: 0
                        )
                    }
                }

                Text(
                    "Deltas are descriptive. MotionOS does not label a positive "
                        + "or negative change as better or worse without a "
                        + "validated task-specific interpretation."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
    }

    private var previousComparableRun: ProductRunRecord? {
        let ordered = library.runs
            .filter {
                $0.protocolKind == run.protocolKind
                    && $0.outcome == .completed
                    && $0.id != run.id
                    && $0.watchSummary != nil
                    && comparableMode($0)
            }
            .sorted {
                ($0.startedAt ?? $0.sealedAt ?? .distantPast)
                    > ($1.startedAt ?? $1.sealedAt ?? .distantPast)
            }

        let currentDate = run.startedAt
            ?? run.sealedAt
            ?? .distantFuture

        return ordered.first {
            ($0.startedAt ?? $0.sealedAt ?? .distantPast)
                < currentDate
        }
    }

    private func comparableMode(
        _ other: ProductRunRecord
    ) -> Bool {
        guard let currentMode = run.productManifest?.captureMode,
              let otherMode = other.productManifest?.captureMode
        else {
            return true
        }
        return currentMode == otherMode
    }

    private func comparisonSubtitle(
        _ previous: ProductRunRecord
    ) -> String {
        guard let date = previous.startedAt ?? previous.sealedAt else {
            return "Previous comparable sealed run"
        }
        return "Previous comparable run · "
            + date.formatted(
                date: .abbreviated,
                time: .omitted
            )
    }

    private func delta(
        _ current: Double?,
        _ previous: Double?
    ) -> Double? {
        guard let current,
              let previous
        else {
            return nil
        }
        return current - previous
    }

    private func deltaTile(
        _ title: String,
        _ value: Double?,
        unit: String,
        decimals: Int = 2
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            if let value {
                Text(
                    String(
                        format: "%+.*f %@",
                        decimals,
                        value,
                        unit
                    )
                )
                .font(
                    .system(
                        .subheadline,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            } else {
                Text("—")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }
}
