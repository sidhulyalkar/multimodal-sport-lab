import MotionOSAppleCapture
import SwiftUI

struct PowerChallengeView: View {
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var power: PowerChallengeCoordinator
    @EnvironmentObject private var personaEvidence: PersonaEvidenceLibrary

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                intro

                switch power.phase {
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
        .navigationTitle("Power Challenge")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Three-jump challenge",
                subtitle: "28 seconds · fixed iPhone Vision camera",
                systemImage: "figure.jumprope",
                accent: .orange
            )

            Text(
                "Perform three comfortable countermovement jumps with your whole "
                    + "body visible. MotionOS compares camera-space movement and "
                    + "repeatability across standardized attempts."
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
                "Use a clear, non-slip area with enough overhead space.",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "Fix the iPhone in place far enough away to keep your head, hands, "
                    + "hips, knees, and feet visible throughout all three attempts."
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
                            power.currentStep?.title
                                ?? "Finish"
                        )
                        .font(.title3.weight(.bold))

                        Text(
                            power.currentStep?.instruction
                                ?? "Stand still while MotionOS closes the challenge."
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
                                PowerProtocolAccumulator
                                    .targetDurationSeconds
                                    - power.elapsedSeconds
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
                    value: power.completionFraction
                )
                .tint(.orange)
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
            switch power.phase {
            case .idle, .failed:
                Button {
                    Task {
                        await power.prepare(camera: camera)
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
                        await power.start(
                            camera: camera,
                            personaEvidence: personaEvidence
                        )
                    }
                } label: {
                    Label(
                        "Start Three-Jump Challenge",
                        systemImage: "record.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.orange)

            case .recording:
                Button(role: .destructive) {
                    Task {
                        await power.finish(
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
                    power.reset()
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

            if let error = power.errorMessage {
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
                "MotionOS is sealing video, summarizing the three attempt windows, "
                    + "and writing Persona evidence."
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
        if let result = power.result {
            VStack(alignment: .leading, spacing: 13) {
                MotionOSSectionHeader(
                    title: "Challenge complete",
                    subtitle:
                        "\(result.validAttemptCount) / 3 attempts with usable geometry",
                    systemImage: "checkmark.circle.fill",
                    accent:
                        result.validAttemptCount >= 2
                            ? .green
                            : .orange
                )

                HStack(spacing: 8) {
                    resultTile(
                        "ROOT SPEED",
                        result.medianPeakRootSpeedCameraMPS.map {
                            String(format: "%.2f m/s", $0)
                        } ?? "—"
                    )
                    resultTile(
                        "ROOT TRAVEL",
                        result.medianRootTravelRangeCameraM.map {
                            String(format: "%.2f m", $0)
                        } ?? "—"
                    )
                    resultTile(
                        "REPEAT CV",
                        result.peakSpeedCoefficientOfVariation.map {
                            String(format: "%.0f%%", $0 * 100)
                        } ?? "—"
                    )
                }

                ForEach(result.attempts) { attempt in
                    HStack {
                        Text("Attempt \(attempt.index)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(
                            attempt.peakRootSpeedCameraMPS.map {
                                String(format: "%.2f m/s", $0)
                            } ?? "insufficient geometry"
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if let url = power.resultURL {
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
                "Kinematic proxy only",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "MotionOS currently reports camera-space root travel, finite-"
                    + "difference root speed, knee-angle range, and repeatability. "
                    + "These are not watts, ground-reaction force, center of mass, "
                    + "or validated jump height."
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
                .minimumScaleFactor(0.68)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }
}
