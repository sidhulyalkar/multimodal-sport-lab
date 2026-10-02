import MotionOSAppleCapture
import SwiftUI

struct MobilityChallengeView: View {
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var mobility: MobilityChallengeCoordinator
    @EnvironmentObject private var personaEvidence: PersonaEvidenceLibrary

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                intro

                switch mobility.phase {
                case .idle, .preparing, .ready, .failed:
                    setupCard
                    controls

                case .recording:
                    liveProtocol
                    cameraCard
                    BodyMovementSceneCard()
                    controls

                case .finalizing:
                    finalizing

                case .complete:
                    resultCard
                    controls
                }

                claimBoundary
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Mobility Challenge")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Guided movement envelope",
                subtitle: "40 seconds · fixed iPhone Vision camera",
                systemImage: "figure.flexibility",
                accent: .purple
            )

            Text(
                "Move only through a comfortable range. MotionOS records the "
                    + "pose envelope it can observe during standardized shoulder, "
                    + "squat, and gentle trunk-rotation windows."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Keep your full body visible and stop any movement that is uncomfortable.",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "Use a fixed camera position and enough room to raise each arm, "
                    + "perform one comfortable squat, and rotate gently without "
                    + "leaving the frame."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if camera.phase == .ready
                || camera.phase == .evidenceReady {
                CameraPreviewView(
                    session: camera.previewSession
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
            }
        }
        .cardStyle()
    }

    private var liveProtocol: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            mobility.currentStep?.title
                                ?? "Finish"
                        )
                        .font(.title3.weight(.bold))

                        Text(
                            mobility.currentStep?.instruction
                                ?? "Return to a comfortable neutral position."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(
                        String(
                            format: "%02.0f",
                            max(
                                0,
                                MobilityProtocolAccumulator
                                    .targetDurationSeconds
                                    - mobility.elapsedSeconds
                            )
                        )
                    )
                    .font(
                        .system(
                            .title2,
                            design: .monospaced,
                            weight: .bold
                        )
                    )
                }

                ProgressView(
                    value: mobility.completionFraction
                )
                .tint(.purple)
            }
            .cardStyle()
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live framing")
                .font(.headline)

            CameraPreviewView(
                session: camera.previewSession
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(.black)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
            )
        }
        .cardStyle()
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            switch mobility.phase {
            case .idle, .failed:
                Button {
                    Task {
                        await mobility.prepare(
                            camera: camera
                        )
                    }
                } label: {
                    Label(
                        "Prepare Challenge",
                        systemImage: "camera.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .preparing:
                ProgressView("Preparing camera…")
                    .frame(maxWidth: .infinity)

            case .ready:
                Button {
                    Task {
                        await mobility.start(
                            camera: camera,
                            personaEvidence: personaEvidence
                        )
                    }
                } label: {
                    Label(
                        "Start Mobility Challenge",
                        systemImage: "record.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.purple)

            case .recording:
                Button(role: .destructive) {
                    Task {
                        await mobility.finish(
                            camera: camera,
                            personaEvidence: personaEvidence
                        )
                    }
                } label: {
                    Label(
                        "Finish Early",
                        systemImage: "stop.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .complete:
                Button {
                    mobility.reset()
                } label: {
                    Label(
                        "Run Again",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .finalizing:
                EmptyView()
            }

            if let error = mobility.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private var finalizing: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Closing challenge")
                .font(.headline)
            Text(
                "MotionOS is sealing video and summarizing observed pose envelopes "
                    + "without converting them into a clinical mobility score."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .cardStyle()
    }

    @ViewBuilder
    private var resultCard: some View {
        if let result = mobility.result {
            VStack(alignment: .leading, spacing: 13) {
                MotionOSSectionHeader(
                    title: "Challenge complete",
                    subtitle: result.hasUsableCoverage
                        ? "All guided windows captured"
                        : "Some guided windows need another pass",
                    systemImage: result.hasUsableCoverage
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill",
                    accent: result.hasUsableCoverage
                        ? .green
                        : .orange
                )

                HStack(spacing: 8) {
                    resultTile(
                        "LEFT SHOULDER",
                        degrees(
                            result.maximumLeftShoulderElevationDegrees
                        )
                    )
                    resultTile(
                        "RIGHT SHOULDER",
                        degrees(
                            result.maximumRightShoulderElevationDegrees
                        )
                    )
                    resultTile(
                        "SIDE DIFF",
                        degrees(
                            result.shoulderElevationAsymmetryDegrees
                        )
                    )
                }

                HStack(spacing: 8) {
                    resultTile(
                        "KNEE ANGLE",
                        degrees(
                            result.minimumMeanKneeAngleDegrees
                        )
                    )
                    resultTile(
                        "TRUNK TWIST",
                        degrees(
                            result.maximumTrunkTwistProxyDegrees
                        )
                    )
                }

                if let url = mobility.resultURL {
                    ShareLink(item: url) {
                        Label(
                            "Export challenge result",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.caption.weight(.semibold))
                    }
                }
            }
            .cardStyle()
        }
    }

    private var claimBoundary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Observed pose envelope only",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "These values describe Vision-observed joint geometry during a "
                    + "specific guided task. They are not a clinical range-of-motion "
                    + "exam, diagnosis, injury-risk estimate, or evidence that a "
                    + "larger range is better."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func resultTile(
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
                .minimumScaleFactor(0.64)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.purple.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }

    private func degrees(
        _ value: Double?
    ) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°", value)
    }
}
