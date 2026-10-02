import MotionOSAppleCapture
import SwiftUI

struct MeasurementReliabilityCard: View {
    @EnvironmentObject private var reliability: PersonaReliabilityCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Measurement repeatability",
                subtitle: "How tightly comparable observations cluster",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .mint
            )

            HStack(spacing: 8) {
                statTile(
                    "REPEATED",
                    String(
                        reliability.snapshot.repeatedSeriesCount
                    )
                )
                statTile(
                    "SAME-DAY ×3",
                    String(
                        reliability.snapshot
                            .sameDayTriplicateSeriesCount
                    )
                )
                statTile(
                    "SESSIONS",
                    String(
                        reliability.snapshot
                            .contributingSessionCount
                    )
                )
            }

            if repeatedSeries.isEmpty {
                Text(
                    "Complete the same standardized challenge at least twice "
                        + "to expose measurement spread. Three same-day repeats "
                        + "are especially useful for separating protocol noise "
                        + "from longer-term change."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(
                    repeatedSeries.prefix(3)
                ) { series in
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 10
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            Text(series.label)
                                .font(
                                    .subheadline
                                        .weight(.semibold)
                                )
                                .lineLimit(1)

                            Text(
                                series.dimension
                                    .displayName
                                    + " · "
                                    + String(
                                        series.sourceSessionCount
                                    )
                                    + " sessions"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(
                            spreadText(series)
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.mint)
                    }
                }
            }

            NavigationLink {
                MeasurementReliabilityView()
            } label: {
                Label(
                    "Open Repeatability Lab",
                    systemImage:
                        "chart.xyaxis.line"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let url =
                reliability.snapshotURL {
                ShareLink(item: url) {
                    Label(
                        "Export repeatability evidence",
                        systemImage:
                            "square.and.arrow.up"
                    )
                    .font(
                        .caption.weight(.semibold)
                    )
                }
            }

            Text(
                "Low spread does not prove accuracy. A sensor or protocol can "
                    + "be consistently biased, so repeatability and validation "
                    + "remain separate questions."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var repeatedSeries:
        [PersonaMetricReliability] {
        reliability.snapshot.series.filter {
            $0.sourceSessionCount >= 2
        }
    }

    private func statTile(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title)
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
        }
        .padding(9)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.mint.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func spreadText(
        _ series: PersonaMetricReliability
    ) -> String {
        let value = formatValue(
            series.medianAbsoluteDeviation,
            unit: series.unit
        )
        if let fraction =
            series.relativeMADFraction {
            return "MAD "
                + value
                + " · "
                + String(
                    format: "%.1f%%",
                    fraction * 100
                )
        }
        return "MAD " + value
    }

    private func formatValue(
        _ value: Double,
        unit: String
    ) -> String {
        let decimals =
            unit == "bpm"
                || unit == "deg"
                ? 0
                : 2
        return String(
            format: "%.*f %@",
            decimals,
            value,
            unit
        )
    }
}

struct MeasurementReliabilityView: View {
    @EnvironmentObject private var reliability: PersonaReliabilityCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(
                spacing: MotionOSDesign.pageSpacing
            ) {
                overview

                if reliability.snapshot.series.isEmpty {
                    emptyState
                } else {
                    ForEach(
                        FitnessPersonaDimension.allCases,
                        id: \.rawValue
                    ) { dimension in
                        let values =
                            series(
                                for: dimension
                            )
                        if !values.isEmpty {
                            dimensionSection(
                                dimension,
                                values: values
                            )
                        }
                    }
                }

                boundary
            }
            .motionOSPageWidth()
            .padding(
                .horizontal,
                MotionOSDesign
                    .pageHorizontalPadding
            )
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Repeatability Lab")
        .navigationBarTitleDisplayMode(
            .inline
        )
    }

    private var overview: some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            MotionOSSectionHeader(
                title: "Evidence repeatability",
                subtitle:
                    "Robust spread across comparable sessions",
                systemImage:
                    "waveform.path.ecg.rectangle",
                accent: .mint
            )

            Text(
                "MotionOS groups observations only when metric, unit, and "
                    + "protocol context match. Median absolute deviation (MAD) "
                    + "summarizes robust spread without turning it into a score."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                overviewTile(
                    "SERIES",
                    String(
                        reliability.snapshot
                            .series.count
                    )
                )
                overviewTile(
                    "REPEATED",
                    String(
                        reliability.snapshot
                            .repeatedSeriesCount
                    )
                )
                overviewTile(
                    "TRIPLICATES",
                    String(
                        reliability.snapshot
                            .sameDayTriplicateSeriesCount
                    )
                )
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Label(
                "No comparable repeated metrics yet",
                systemImage:
                    "circle.dotted"
            )
            .font(
                .subheadline.weight(.semibold)
            )

            Text(
                "Run the same Power, Mobility, or movement protocol more than "
                    + "once. MotionOS will keep different protocols and units "
                    + "separate instead of blending incompatible evidence."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func dimensionSection(
        _ dimension: FitnessPersonaDimension,
        values: [PersonaMetricReliability]
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            MotionOSSectionHeader(
                title: dimension.displayName,
                subtitle:
                    String(values.count)
                        + (
                            values.count == 1
                                ? " comparable metric"
                                : " comparable metrics"
                        ),
                systemImage:
                    icon(for: dimension),
                accent: .mint
            )

            ForEach(values) { series in
                reliabilityRow(series)

                if series.id
                    != values.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private func reliabilityRow(
        _ series: PersonaMetricReliability
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 9
        ) {
            HStack(
                alignment: .firstTextBaseline
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 2
                ) {
                    Text(series.label)
                        .font(
                            .subheadline
                                .weight(.semibold)
                        )
                    Text(
                        String(
                            series.sourceSessionCount
                        )
                            + (
                                series.sourceSessionCount
                                    == 1
                                    ? " session"
                                    : " sessions"
                            )
                            + " · "
                            + spanText(
                                series.spanDays
                            )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(
                    series.coverage.displayName
                )
                .font(
                    .caption.weight(.semibold)
                )
                .foregroundStyle(
                    series.sourceSessionCount
                        >= 2
                        ? Color.mint
                        : Color.secondary
                )
            }

            HStack(spacing: 8) {
                metricTile(
                    "MEDIAN",
                    formatValue(
                        series.median,
                        unit: series.unit
                    )
                )
                metricTile(
                    "MAD",
                    formatValue(
                        series
                            .medianAbsoluteDeviation,
                        unit: series.unit
                    )
                )
                metricTile(
                    "LATEST Δ",
                    signedValue(
                        series
                            .latestDeltaFromMedian,
                        unit: series.unit
                    )
                )
            }

            HStack(
                alignment: .firstTextBaseline
            ) {
                if let fraction =
                    series.relativeMADFraction {
                    Text(
                        "Robust spread is "
                            + String(
                                format: "%.1f%%",
                                fraction * 100
                            )
                            + " of the median."
                    )
                } else {
                    Text(
                        "Relative spread is omitted because the median is near zero."
                    )
                }

                Spacer()

                Text(
                    "same-day max "
                        + String(
                            series
                                .maximumSameDayRepeatCount
                        )
                        + "×"
                )
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var boundary: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {
            Label(
                "Repeatability is not accuracy",
                systemImage:
                    "checkmark.shield"
            )
            .font(
                .subheadline.weight(.semibold)
            )

            Text(
                reliability.snapshot
                    .claimBoundary
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error =
                reliability.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private func overviewTile(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title)
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
        }
        .padding(9)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func metricTile(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .caption,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(9)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func series(
        for dimension:
            FitnessPersonaDimension
    ) -> [PersonaMetricReliability] {
        reliability.snapshot.series.filter {
            $0.dimension == dimension
        }
    }

    private func formatValue(
        _ value: Double,
        unit: String
    ) -> String {
        let decimals =
            unit == "bpm"
                || unit == "deg"
                ? 0
                : 2
        return String(
            format: "%.*f %@",
            decimals,
            value,
            unit
        )
    }

    private func signedValue(
        _ value: Double,
        unit: String
    ) -> String {
        let decimals =
            unit == "bpm"
                || unit == "deg"
                ? 0
                : 2
        return String(
            format: "%+.*f %@",
            decimals,
            value,
            unit
        )
    }

    private func spanText(
        _ days: Double
    ) -> String {
        if days < 1 {
            return "same day"
        }
        if days < 2 {
            return "1 day span"
        }
        return String(
            format: "%.0f day span",
            days
        )
    }

    private func icon(
        for dimension:
            FitnessPersonaDimension
    ) -> String {
        switch dimension {
        case .movement:
            return "figure.cooldown"
        case .cardiovascularResponse:
            return "heart.fill"
        case .power:
            return "bolt.fill"
        case .mobility:
            return "figure.flexibility"
        case .recovery:
            return "moon.stars.fill"
        case .body:
            return "person.crop.rectangle"
        }
    }
}
