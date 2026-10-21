import Charts
import MotionOSAppleCapture
import SwiftUI

/// The first rider-facing interpretation of the existing image-plane board
/// signals. All tiles are backed by persisted session metrics, never previews
/// or synthesized values.
struct IndoBoardControlInsightsCard: View {
    let run: ProductRunRecord

    private var values: [String: Double] {
        run.productManifest?.coachSummary?.numericMetrics ?? [:]
    }

    private var repeatCenter: Double? {
        values["board_control_repeat_center_fraction"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            MotionOSSectionHeader(
                title: "Balance intelligence",
                subtitle: "Measured movement patterns from this session",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .indigo
            )

            if let first = values["board_control_early_center_fraction"],
               let repeatValue = repeatCenter,
               let earlyRate = values["board_control_early_reversals_per_min"],
               let repeatRate = values["board_control_repeat_reversals_per_min"] {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Control consistency")
                        .font(.subheadline.weight(.semibold))
                    fractionRow("First natural balance block", value: first)
                    fractionRow("Repeat natural balance block", value: repeatValue)

                    Text(changeDescription(repeatValue - first))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    metricTile(
                        title: "EARLY CORRECTIONS",
                        value: String(format: "%.1f", earlyRate),
                        unit: "reversals/min"
                    )
                    metricTile(
                        title: "REPEAT CORRECTIONS",
                        value: String(format: "%.1f", repeatRate),
                        unit: "reversals/min"
                    )
                }

                Text(
                    "Direction reversals are a roller-motion proxy, not " +
                    "direct measurements of muscular effort or nervous-system adaptation."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)

                if let exposure = values["board_control_positive_side_fraction"] {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directional exposure")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f%% / %.0f%%",
                                        (1 - exposure) * 100, exposure * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            HStack(spacing: 2) {
                                Color.cyan
                                    .frame(width: max(0, geometry.size.width * (1 - exposure) - 1))
                                Color.indigo
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 9)

                        Text(
                            "Negative / positive deck-axis occupancy outside the center. " +
                            "This is not left/right foot pressure; camera and board " +
                            "orientation must be matched before comparing direction across sessions."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let recoveries = values["board_recovery_count"],
                   recoveries >= 3,
                   let recovery = values["board_p90_recovery_ms"] {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("Longer recoveries (P90)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2f s", recovery / 1_000))
                            .font(.headline.monospacedDigit())
                    }
                    Text(
                        "Time for the tracked roller to return toward the central deck region."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "Not enough qualified board tracking for matched-block insights.",
                    systemImage: "viewfinder"
                )
                .font(.subheadline.weight(.medium))
                Text(
                    "Keep the entire board and roller visible during both natural " +
                    "balance blocks. MotionOS waits for adequate confidence, " +
                    "coverage, and observed duration before reporting changes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(
                "Experimental image-plane board/roller estimates. Changes between " +
                "the first and repeat balance blocks are descriptive, not proof " +
                "of fatigue, injury, asymmetrical force, or improved skill."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func fractionRow(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: min(1, max(0, value)))
                .tint(.indigo)
        }
    }

    private func changeDescription(_ change: Double) -> String {
        let magnitude = abs(change * 100)
        if magnitude < 5 {
            return "Both balance blocks had similar observed center time."
        }
        let direction = change < 0 ? "less" : "more"
        return String(
            format: "The repeat balance block had %.0f percentage points %@ center time. Task context and measurement noise can influence this difference.",
            magnitude,
            direction
        )
    }

    private func metricTile(
        title: String,
        value: String,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct IndoBoardControlProgressCard: View {
    private enum Metric: String, CaseIterable, Identifiable {
        case center = "Control"
        case corrections = "Corrections"

        var id: String { rawValue }
        var key: String {
            switch self {
            case .center: "board_control_repeat_center_fraction"
            case .corrections: "board_control_repeat_reversals_per_min"
            }
        }
        var unit: String {
            switch self {
            case .center: "Center time (%)"
            case .corrections: "Reversals/min"
            }
        }
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    @EnvironmentObject private var library: ProductRunLibrary
    @State private var selected: Metric = .center

    private var eligibleRuns: [ProductRunRecord] {
        let candidates = library.runs.filter {
            $0.protocolKind == FieldProtocolKind.indoBoard.rawValue
                && $0.protocolVersion == IndoBoardProductProtocol.protocolID
                && $0.outcome == .completed
                && $0.productManifest?.coachSummary?
                    .numericMetrics?["board_control_repeat_center_fraction"] != nil
                && ($0.startedAt ?? $0.sealedAt) != nil
        }
        // Protocol and capture mode must match before making a longitudinal
        // comparison. Directional polarity is not compared across cameras.
        guard let mostRecent = candidates.max(by: {
            ($0.startedAt ?? $0.sealedAt ?? .distantPast)
                < ($1.startedAt ?? $1.sealedAt ?? .distantPast)
        }) else {
            return []
        }
        return candidates.filter {
            $0.captureMode == mostRecent.captureMode
        }
    }

    private var points: [Point] {
        eligibleRuns.compactMap { run in
            guard let date = run.startedAt ?? run.sealedAt,
                  let raw = run.productManifest?.coachSummary?
                    .numericMetrics?[selected.key], raw.isFinite
            else { return nil }
            return Point(
                id: run.id,
                date: date,
                value: selected == .center ? raw * 100 : raw
            )
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Balance over time",
                subtitle: "Qualified, protocol-matched Indo Board sessions",
                systemImage: "chart.xyaxis.line",
                accent: .indigo
            )

            Picker("Movement metric", selection: $selected) {
                ForEach(Metric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Session", point.date),
                        y: .value(selected.unit, point.value)
                    )
                    .foregroundStyle(.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    PointMark(
                        x: .value("Session", point.date),
                        y: .value(selected.unit, point.value)
                    )
                    .foregroundStyle(.indigo)
                    .symbolSize(45)
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 175)

                if let first = points.first, let last = points.last {
                    HStack {
                        Text("First: " + display(first.value))
                        Spacer()
                        Text("Latest: " + display(last.value))
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                }
            } else {
                Label(
                    points.isEmpty
                        ? "Record a qualified balance session to begin."
                        : "Repeat this setup to unlock a movement trend.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 14)
            }

            Text(
                "These are roller-motion proxies from comparable capture modes, " +
                "not population scores. Camera geometry, task difficulty, and " +
                "ordinary day-to-day variation may affect the trend."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private func display(_ value: Double) -> String {
        switch selected {
        case .center: String(format: "%.0f%%", value)
        case .corrections: String(format: "%.1f/min", value)
        }
    }
}

struct IndoBoardTodayFocusCard: View {
    @Binding var selectedTab: MotionOSTab
    @EnvironmentObject private var library: ProductRunLibrary

    private var latest: ProductRunRecord? {
        library.runs.first {
            $0.protocolKind == FieldProtocolKind.indoBoard.rawValue
                && $0.outcome == .completed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Your next balance session",
                subtitle: latest == nil
                    ? "Start your movement baseline"
                    : "Repeat a comparable session to track change",
                systemImage: "target",
                accent: .indigo
            )
            Text(
                latest?.productManifest?.coachSummary?.drill
                    ?? "Begin with a guided Indo Board capture. Keep the full board and roller visible."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                selectedTab = .record
            } label: {
                Label("Record Indo Board", systemImage: "record.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .cardStyle()
    }
}
