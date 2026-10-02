import MotionOSAppleCapture
import SwiftUI

struct GhostComparisonCard: View {
    let run: ProductRunRecord

    @EnvironmentObject private var library: ProductRunLibrary
    @EnvironmentObject private var ghost: GhostComparisonCoordinator

    @State private var progress = 0.50
    @State private var viewpoint: GhostSceneViewpoint = .orbit

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            MotionOSSectionHeader(
                title: "Reference ghost",
                subtitle: subtitle,
                systemImage: "person.2.wave.2",
                accent: .cyan
            )

            if run.cameraJournalURL == nil {
                unavailable
            } else if ghost.isPinnedReference(run) {
                pinnedReferenceState
            } else if let reference = referenceRun {
                referenceSummary(reference)

                if comparisonReady(
                    current: run,
                    reference: reference
                ) {
                    comparisonView(
                        current: run,
                        reference: reference
                    )
                } else {
                    compareAction(reference)
                }

                replaceReferenceAction
            } else {
                emptyReferenceState
            }

            if let error = ghost.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private var subtitle: String {
        if run.cameraJournalURL == nil {
            return "Vision pose evidence is required"
        }
        if ghost.isPinnedReference(run) {
            return "This session is the pinned comparison reference"
        }
        if referenceRun != nil {
            return "Overlay this run against your pinned reference"
        }
        return "Pin one comparable session, then revisit another"
    }

    private var referenceRun: ProductRunRecord? {
        ghost.referenceRun(
            for: run,
            in: library
        )
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "No 3D pose journal is linked to this run.",
                systemImage: "camera.metering.unknown"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "Ghost comparison uses the sealed iPhone Vision pose journal. "
                    + "Watch-only or camera-missing runs remain valid sessions, "
                    + "but they cannot produce a 3D movement ghost."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyReferenceState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Use a completed run you want to learn from as the reference. "
                    + "MotionOS will only compare it with runs that share the same "
                    + "sport, protocol, and capture mode."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                ghost.pinReference(run)
            } label: {
                Label(
                    "Pin This Session as Reference",
                    systemImage: "pin.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Text(
                "MotionOS does not automatically call a run your “best.” "
                    + "You choose the reference until a protocol has a validated "
                    + "metric whose direction is actually meaningful."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var pinnedReferenceState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Pinned reference for this protocol",
                systemImage: "pin.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.cyan)

            Text(
                "Open another comparable session to overlay its time-normalized "
                    + "Vision pose against this reference."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(role: .destructive) {
                ghost.clearReference(for: run)
            } label: {
                Label(
                    "Clear Reference",
                    systemImage: "pin.slash"
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private func referenceSummary(
        _ reference: ProductRunRecord
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .foregroundStyle(.indigo)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pinned reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(
                    referenceDate(reference)
                )
                .font(.subheadline.weight(.semibold))
            }

            Spacer()

            Text(
                String(reference.runID.suffix(8))
            )
            .font(
                .system(
                    .caption2,
                    design: .monospaced,
                    weight: .semibold
                )
            )
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            Color.indigo.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private func compareAction(
        _ reference: ProductRunRecord
    ) -> some View {
        switch ghost.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Building compact pose trajectories…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)

        default:
            Button {
                Task {
                    await ghost.loadComparison(
                        current: run,
                        reference: reference
                    )
                }
            } label: {
                Label(
                    "Compare with Reference Ghost",
                    systemImage: "person.2.gobackward"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var replaceReferenceAction: some View {
        Button {
            ghost.pinReference(run)
        } label: {
            Label(
                "Use This Session as New Reference",
                systemImage: "pin"
            )
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func comparisonView(
        current: ProductRunRecord,
        reference: ProductRunRecord
    ) -> some View {
        if let currentTrajectory = ghost.currentTrajectory,
           let referenceTrajectory = ghost.referenceTrajectory,
           let currentFrame = sampleFrame(
                trajectory: currentTrajectory,
                progress: progress
           ),
           let referenceFrame = sampleFrame(
                trajectory: referenceTrajectory,
                progress: progress
           ),
           let summary = ghost.summary {
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
                    current: currentFrame,
                    reference: referenceFrame,
                    viewpoint: viewpoint
                )
                .frame(height: 300)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                )
                .overlay(alignment: .topLeading) {
                    ghostLegend
                        .padding(10)
                }

                VStack(spacing: 4) {
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
                    .font(
                        .system(
                            .caption2,
                            design: .monospaced,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    comparisonMetric(
                        "MEAN JOINT Δ",
                        distanceText(
                            summary.meanJointDistanceM
                        )
                    )
                    comparisonMetric(
                        "MEDIAN JOINT Δ",
                        distanceText(
                            summary.medianJointDistanceM
                        )
                    )
                    comparisonMetric(
                        "PAIRS",
                        "\(summary.samplePairCount)"
                    )
                }

                if !summary.jointDifferences.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Largest geometric differences")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(
                            summary.jointDifferences.prefix(4)
                        ) { difference in
                            HStack {
                                Text(
                                    humanize(
                                        difference.jointID
                                    )
                                )
                                .font(.caption)

                                Spacer()

                                Text(
                                    String(
                                        format: "%.1f cm",
                                        difference.meanDistanceM * 100
                                    )
                                )
                                .font(
                                    .system(
                                        .caption,
                                        design: .monospaced,
                                        weight: .semibold
                                    )
                                )
                            }
                        }
                    }
                }

                Text(summary.claimBoundary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ghostLegend: some View {
        HStack(spacing: 8) {
            legendItem(
                "Current",
                color: .cyan
            )
            legendItem(
                "Reference",
                color: .indigo
            )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
    }

    private func legendItem(
        _ label: String,
        color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
    }

    private func comparisonMetric(
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

    private func sampleFrame(
        trajectory: BodyPoseTrajectory,
        progress: Double
    ) -> BodyMovementFrame? {
        GhostComparisonEngine.nearestSample(
            to: progress,
            in: trajectory.samples
        )?.frame
    }

    private func comparisonReady(
        current: ProductRunRecord,
        reference: ProductRunRecord
    ) -> Bool {
        guard case .ready = ghost.state,
              let summary = ghost.summary
        else {
            return false
        }

        return summary.currentSessionID
                == current.cameraSessionID
            && summary.referenceSessionID
                == reference.cameraSessionID
    }

    private func distanceText(
        _ value: Double?
    ) -> String {
        guard let value else { return "—" }
        return String(
            format: "%.1f cm",
            value * 100
        )
    }

    private func referenceDate(
        _ reference: ProductRunRecord
    ) -> String {
        let date =
            reference.startedAt
                ?? reference.sealedAt

        return date?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "Unknown date"
    }

    private func humanize(
        _ value: String
    ) -> String {
        let spaced = value.replacingOccurrences(
            of: "_",
            with: " "
        )
        var output = ""
        for character in spaced {
            if character.isUppercase,
               !output.isEmpty,
               output.last != " " {
                output.append(" ")
            }
            output.append(character)
        }
        return output
            .split(separator: " ")
            .map {
                $0.prefix(1).uppercased()
                    + $0.dropFirst()
            }
            .joined(separator: " ")
    }
}
