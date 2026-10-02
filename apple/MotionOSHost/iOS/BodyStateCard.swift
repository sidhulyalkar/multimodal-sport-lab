import MotionOSAppleCapture
import SwiftUI

struct BodyStateCard: View {
    @EnvironmentObject private var health: HealthDataCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MotionOSSectionHeader(
                title: "Daily context",
                subtitle: subtitle,
                systemImage: "heart.text.square",
                accent: .pink
            )

            switch health.state {
            case .unavailable:
                unavailableState

            case .notRequested:
                connectState

            case .requesting, .syncing:
                progressState

            case .ready:
                contextGrid
                sourceAndActions

            case .failed(let message):
                failedState(message)
            }
        }
        .cardStyle()
    }

    private var subtitle: String {
        switch health.state {
        case .ready:
            return "Source-reported HealthKit context"
        case .syncing:
            return "Refreshing longitudinal context"
        case .requesting:
            return "Requesting Health access"
        case .notRequested:
            return "Optional low-friction longitudinal context"
        case .unavailable:
            return "Health data is unavailable on this device"
        case .failed:
            return "Health data needs attention"
        }
    }

    private var unavailableState: some View {
        Label(
            "HealthKit is not available on this device.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var connectState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "MotionOS can privately import body measurements, resting heart "
                    + "rate, HRV, sleep, and workout history from apps and devices "
                    + "that write those values to Apple Health."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await health.requestAccessAndSync()
                }
            } label: {
                Label(
                    "Connect Apple Health",
                    systemImage: "heart.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.pink)

            Text(
                "MotionOS asks only for read access. iOS lets you choose each "
                    + "data type individually."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var progressState: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(health.state.label)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .frame(minHeight: 48)
    }

    private func failedState(
        _ message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Health sync needs attention",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Try Again") {
                    Task {
                        await health.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Request Access") {
                    Task {
                        await health.requestAccessAndSync()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var contextGrid: some View {
        let context = health.latestContext

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                contextTile(
                    title: "BODY MASS",
                    value: bodyMassText(
                        context.latestBodyMass
                    ),
                    source: sourceText(
                        context.latestBodyMass
                    )
                )
                contextTile(
                    title: "BODY FAT",
                    value: bodyFatText(
                        context.latestBodyFatPercentage
                    ),
                    source: sourceText(
                        context.latestBodyFatPercentage
                    )
                )
            }

            HStack(spacing: 8) {
                contextTile(
                    title: "RESTING HR",
                    value: heartRateText(
                        context.latestRestingHeartRate
                    ),
                    source: sourceText(
                        context.latestRestingHeartRate
                    )
                )
                contextTile(
                    title: "HRV",
                    value: hrvText(
                        context.latestHRV
                    ),
                    source: sourceText(
                        context.latestHRV
                    )
                )
            }

            HStack(spacing: 8) {
                contextTile(
                    title: "LEAN MASS",
                    value: bodyMassText(
                        context.latestLeanBodyMass
                    ),
                    source: sourceText(
                        context.latestLeanBodyMass
                    )
                )
                contextTile(
                    title: "SLEEP / 24H",
                    value: sleepText(
                        context.prior24HourSleepSeconds
                    ),
                    source: "union of source-reported sleep"
                )
            }
        }
    }

    private var sourceAndActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(health.importedObservationCount) imported observations"
                    )
                    .font(.caption.weight(.semibold))

                    Text(lastSyncText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await health.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh Apple Health data")
            }

            if let url = health.timelineURL {
                ShareLink(item: url) {
                    Label(
                        "Export body-state timeline",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.caption.weight(.semibold))
                }
            }

            if let error = health.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Apple Health does not reveal which read permissions you denied. "
                    + "A missing value can therefore mean either no source data "
                    + "exists or that MotionOS cannot read that type."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Text(
                "Body composition, sleep, HRV, and resting heart rate remain "
                    + "source-reported context. MotionOS does not treat them as "
                    + "diagnosis, readiness, or causal explanations for performance."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func contextTile(
        title: String,
        value: String,
        source: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    .system(
                        .headline,
                        design: .rounded,
                        weight: .semibold
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    private func bodyMassText(
        _ observation: BodyStateObservation?
    ) -> String {
        guard let value = observation?.numericValue else {
            return "—"
        }
        return String(format: "%.1f kg", value)
    }

    private func bodyFatText(
        _ observation: BodyStateObservation?
    ) -> String {
        guard let fraction = observation?.numericValue else {
            return "—"
        }
        return String(
            format: "%.1f%%",
            fraction * 100
        )
    }

    private func heartRateText(
        _ observation: BodyStateObservation?
    ) -> String {
        guard let value = observation?.numericValue else {
            return "—"
        }
        return String(format: "%.0f bpm", value)
    }

    private func hrvText(
        _ observation: BodyStateObservation?
    ) -> String {
        guard let value = observation?.numericValue else {
            return "—"
        }
        return String(format: "%.0f ms", value)
    }

    private func sleepText(
        _ seconds: TimeInterval
    ) -> String {
        guard seconds > 0 else {
            return "—"
        }
        return String(
            format: "%.1f h",
            seconds / 3_600
        )
    }

    private func sourceText(
        _ observation: BodyStateObservation?
    ) -> String {
        guard let observation else {
            return "no readable source yet"
        }

        let source =
            observation.source.name
                ?? observation.source.bundleIdentifier
                ?? "Health source"
        let age = observation.startDate.formatted(
            date: .abbreviated,
            time: .omitted
        )
        return source + " · " + age
    }

    private var lastSyncText: String {
        guard let date = health.lastSyncAt else {
            return "No completed sync yet"
        }

        return "Last sync "
            + date.formatted(
                date: .omitted,
                time: .shortened
            )
    }
}
