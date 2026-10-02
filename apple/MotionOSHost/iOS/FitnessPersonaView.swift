import MotionOSAppleCapture
import SwiftUI

struct FitnessPersonaView: View {
    @EnvironmentObject private var persona: FitnessPersonaCoordinator
    @EnvironmentObject private var library: ProductRunLibrary

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                hero
                PersonalBodyModelCard()
                BodyStateCard()
                FitnessChallengesCard(
                    mobilityAvailable: true
                )
                evidenceMap

                if !longitudinalBaselines.isEmpty {
                    longitudinalSignals
                }

                evidenceGaps
                dataBoundary
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Persona")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            library.refresh()
            persona.rebuild(from: library.runs)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .indigo.opacity(0.95),
                                    .cyan.opacity(0.80),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)

                    Image(systemName: "figure.stand")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitness Persona")
                        .font(.title2.weight(.bold))
                    Text("Your evidence-backed physical profile")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("EVIDENCE COVERAGE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(
                        "\(persona.snapshot.measuredDimensionCount)"
                            + " / "
                            + "\(FitnessPersonaDimension.allCases.count)"
                    )
                    .font(
                        .system(
                            .caption,
                            design: .rounded,
                            weight: .semibold
                        )
                    )
                    .monospacedDigit()
                }

                ProgressView(
                    value: Double(persona.snapshot.measuredDimensionCount),
                    total: Double(FitnessPersonaDimension.allCases.count)
                )
                .tint(.indigo)

                Text(
                    "\(persona.snapshot.sourceSessionCount) completed session"
                        + (
                            persona.snapshot.sourceSessionCount == 1
                                ? ""
                                : "s"
                        )
                        + " currently contribute to the profile."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                personaPill(
                    title: bodyModelTitle,
                    systemImage: "person.crop.rectangle"
                )

                personaPill(
                    title: longitudinalTitle,
                    systemImage: "clock.arrow.circlepath"
                )
            }

            if let url = persona.snapshotURL {
                ShareLink(item: url) {
                    Label(
                        "Export persona snapshot",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .cardStyle()
    }

    private var evidenceMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Evidence map",
                subtitle: "What MotionOS can currently characterize",
                systemImage: "square.grid.2x2",
                accent: .indigo
            )

            ForEach(persona.snapshot.dimensions) { state in
                dimensionRow(state)

                if state.id != persona.snapshot.dimensions.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private func dimensionRow(
        _ state: FitnessPersonaDimensionState
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon(for: state.dimension))
                .font(.body.weight(.semibold))
                .foregroundStyle(tint(for: state.coverage))
                .frame(width: 30, height: 30)
                .background(
                    tint(for: state.coverage).opacity(0.10),
                    in: RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(state.dimension.displayName)
                    .font(.subheadline.weight(.semibold))

                if let baseline = state.baselines.first {
                    Text(
                        baseline.label
                            + " · "
                            + latestValueText(baseline)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text(gapDescription(for: state.dimension))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(state.coverage.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint(for: state.coverage))

                if state.evidenceSessionCount > 0 {
                    Text(
                        "\(state.evidenceSessionCount) session"
                            + (
                                state.evidenceSessionCount == 1
                                    ? ""
                                    : "s"
                            )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 54)
    }

    private var longitudinalSignals: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Longitudinal signals",
                subtitle: "Descriptive baselines from comparable sessions",
                systemImage: "chart.line.uptrend.xyaxis",
                accent: .cyan
            )

            ForEach(longitudinalBaselines.prefix(4)) { baseline in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(baseline.label)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(
                            "\(baseline.sampleCount)×"
                        )
                        .font(
                            .system(
                                .caption,
                                design: .rounded,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        metricTile(
                            "LATEST",
                            latestValueText(baseline)
                        )
                        metricTile(
                            "MEDIAN",
                            valueText(
                                baseline.median,
                                unit: baseline.unit
                            )
                        )
                        metricTile(
                            "DELTA",
                            signedValueText(
                                baseline.latestDeltaFromMedian,
                                unit: baseline.unit
                            )
                        )
                    }

                    if let trend = baseline.trendPer30Days {
                        Text(
                            "30-day descriptive trend: "
                                + signedValueText(
                                    trend,
                                    unit: baseline.unit
                                )
                                + ". Direction is not labeled better or worse."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .cardStyle()
    }

    private var evidenceGaps: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Unmeasured territory",
                subtitle: gapStates.isEmpty
                    ? "Every current domain has at least one observation"
                    : "Future challenges can fill these parts of the profile",
                systemImage: "map",
                accent: .purple
            )

            if gapStates.isEmpty {
                Label(
                    "The profile has observations in every current evidence domain.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(gapStates) { state in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: state.dimension))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.dimension.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(gapDescription(for: state.dimension))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(
                "MotionOS should add a domain only when a protocol actually "
                    + "measures something relevant. Missing evidence stays missing."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var dataBoundary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Evidence, not a fitness score",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(persona.snapshot.claimBoundary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Generated "
                    + persona.snapshot.generatedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let error = persona.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var longitudinalBaselines: [PersonaMetricBaseline] {
        persona.snapshot.dimensions
            .flatMap(\.baselines)
            .filter { $0.sampleCount >= 2 }
            .sorted {
                if $0.sampleCount != $1.sampleCount {
                    return $0.sampleCount > $1.sampleCount
                }
                return $0.latestObservedAt > $1.latestObservedAt
            }
    }

    private var gapStates: [FitnessPersonaDimensionState] {
        persona.snapshot.dimensions.filter {
            $0.coverage == .none
        }
    }

    private var bodyModelTitle: String {
        if let version = persona.snapshot.bodyModelVersion {
            return "Body " + version
        }
        return "Body not calibrated"
    }

    private var longitudinalTitle: String {
        if persona.snapshot.longitudinalDimensionCount > 0 {
            return "\(persona.snapshot.longitudinalDimensionCount) longitudinal"
        }
        return "Building baseline"
    }

    private func personaPill(
        title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color.primary.opacity(0.045),
                in: Capsule()
            )
    }

    private func metricTile(
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
                        .caption,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

    private func latestValueText(
        _ baseline: PersonaMetricBaseline
    ) -> String {
        valueText(
            baseline.latestValue,
            unit: baseline.unit
        )
    }

    private func valueText(
        _ value: Double,
        unit: String
    ) -> String {
        let decimals = unit == "bpm" ? 0 : 2
        return String(
            format: "%.*f %@",
            decimals,
            value,
            unit
        )
    }

    private func signedValueText(
        _ value: Double,
        unit: String
    ) -> String {
        let decimals = unit == "bpm" ? 0 : 2
        return String(
            format: "%+.*f %@",
            decimals,
            value,
            unit
        )
    }

    private func tint(
        for coverage: PersonaEvidenceCoverage
    ) -> Color {
        switch coverage {
        case .none:
            return .secondary
        case .singleSession:
            return .orange
        case .repeated:
            return .cyan
        case .longitudinal:
            return .indigo
        }
    }

    private func icon(
        for dimension: FitnessPersonaDimension
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

    private func gapDescription(
        for dimension: FitnessPersonaDimension
    ) -> String {
        switch dimension {
        case .movement:
            return "Repeat a standardized movement protocol."
        case .cardiovascularResponse:
            return "Capture heart rate during a comparable effort."
        case .power:
            return "A standardized jump or power protocol is not implemented yet."
        case .mobility:
            return "A calibrated movement-envelope protocol is not implemented yet."
        case .recovery:
            return "Longitudinal recovery context is not connected yet."
        case .body:
            return "Run a future guided body calibration before using geometry here."
        }
    }
}
