import MotionOSAppleCapture
import SwiftUI

struct GhostComparisonView: View {
    let current: ProductRunRecord
    let reference: ProductRunRecord

    @EnvironmentObject private var ghost: GhostComparisonCoordinator

    @State private var progress = 0.5
    @State private var viewpoint: GhostSceneViewpoint = .orbit

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header

                switch ghost.state {
                case .idle, .loading:
                    loading

                case .ready:
                    if let currentFrame,
                       let referenceFrame {
                        scene(
                            current: currentFrame,
                            reference: referenceFrame
                        )
                        summaryCard
                        jointDifferences
                    } else {
                        unavailable(
                            "The compact trajectories do not contain a comparable frame at this position."
                        )
                    }

                case .failed(let message):
                    unavailable(message)
                }
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Ghost Comparison")
        .navigationBarTitleDisplayMode(.inline)
        .task(
            id: current.runID + "|" + reference.runID
        ) {
            await ghost.loadComparison(
                current: current,
                reference: reference
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "You vs your reference",
                subtitle: referenceSubtitle,
                systemImage: "person.2.wave.2",
                accent: .cyan
            )

            HStack(spacing: 10) {
                legend(
                    "Current",
                    color: .cyan
                )
                legend(
                    "Reference",
                    color: .indigo
                )
                Spacer()
            }

            Text(
                "The two Vision trajectories are normalized by session progress. "
                    + "MotionOS reports geometry differences without deciding which "
                    + "movement is better."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Building compact pose trajectories…")
                .font(.headline)
            Text(
                "This reads the two sealed camera pose journals, downsamples them, "
                    + "and aligns them by normalized session progress."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardStyle()
    }

    private func scene(
        current: BodyMovementFrame,
        reference: BodyMovementFrame
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Ghost viewpoint",
                selection: $viewpoint
            ) {
                ForEach(
                    GhostSceneViewpoint.allCases
                ) { item in
                    Text(item.rawValue)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)

            GhostPoseScene3D(
                current: current,
                reference: reference,
                viewpoint: viewpoint
            )
            .frame(height: 330)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )

            VStack(spacing: 6) {
                Slider(
                    value: $progress,
                    in: 0...1
                )
                .tint(.cyan)

                HStack {
                    Text("START")
                    Spacer()
                    Text(
                        String(
                            format: "%3.0f%%",
                            progress * 100
                        )
                    )
                    Spacer()
                    Text("END")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = ghost.summary {
            VStack(alignment: .leading, spacing: 12) {
                MotionOSSectionHeader(
                    title: "Pose difference",
                    subtitle:
                        "\(summary.samplePairCount) aligned samples · "
                        + "\(summary.jointObservationCount) joint comparisons",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    accent: .purple
                )

                HStack(spacing: 8) {
                    metric(
                        "MEAN",
                        distance(
                            summary.meanJointDistanceM
                        )
                    )
                    metric(
                        "MEDIAN",
                        distance(
                            summary.medianJointDistanceM
                        )
                    )
                    metric(
                        "JOINTS",
                        "\(summary.jointDifferences.count)"
                    )
                }

                if let url = ghost.summaryURL {
                    ShareLink(item: url) {
                        Label(
                            "Export comparison",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.caption.weight(.semibold))
                    }
                }

                Text(summary.claimBoundary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private var jointDifferences: some View {
        if let summary = ghost.summary,
           !summary.jointDifferences.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MotionOSSectionHeader(
                    title: "Largest geometry differences",
                    subtitle: "Descriptive mean root-relative distance",
                    systemImage: "ruler",
                    accent: .orange
                )

                ForEach(
                    summary.jointDifferences.prefix(8)
                ) { item in
                    HStack {
                        Text(
                            humanize(item.jointID)
                        )
                        .font(.subheadline.weight(.medium))

                        Spacer()

                        Text(
                            String(
                                format: "%.1f cm",
                                item.meanDistanceM * 100
                            )
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)

                        Text(
                            String(
                                format: "p95 %.1f",
                                item.p95DistanceM * 100
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }

                Text(
                    "Large differences can reflect timing, camera geometry, task "
                        + "execution, or pose estimation. They are not automatically "
                        + "errors or regressions."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
    }

    private func unavailable(
        _ message: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(
                systemName: "exclamationmark.triangle"
            )
            .font(.title2)
            .foregroundStyle(.orange)

            Text("Ghost comparison unavailable")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .cardStyle()
    }

    private var currentFrame: BodyMovementFrame? {
        guard let trajectory =
                ghost.currentTrajectory
        else {
            return nil
        }

        return GhostComparisonEngine.nearestSample(
            to: progress,
            in: trajectory.samples
        )?.frame
    }

    private var referenceFrame: BodyMovementFrame? {
        guard let trajectory =
                ghost.referenceTrajectory
        else {
            return nil
        }

        return GhostComparisonEngine.nearestSample(
            to: progress,
            in: trajectory.samples
        )?.frame
    }

    private var referenceSubtitle: String {
        if let date =
            reference.startedAt
                ?? reference.sealedAt {
            return "User-pinned reference · "
                + date.formatted(
                    date: .abbreviated,
                    time: .omitted
                )
        }
        return "User-pinned comparable reference session"
    }

    private func legend(
        _ title: String,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func metric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
                .lineLimit(1)
                .minimumScaleFactor(0.68)
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

    private func distance(
        _ value: Double?
    ) -> String {
        guard let value else { return "—" }
        return String(
            format: "%.1f cm",
            value * 100
        )
    }

    private func humanize(
        _ value: String
    ) -> String {
        value
            .replacingOccurrences(
                of: "_",
                with: " "
            )
            .split(separator: " ")
            .map {
                $0.prefix(1).uppercased()
                    + $0.dropFirst()
            }
            .joined(separator: " ")
    }
}
