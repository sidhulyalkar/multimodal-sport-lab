import MotionOSAppleCapture
import SwiftUI

struct GuidedBodyCalibrationView: View {
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var calibration: GuidedBodyCalibrationCoordinator
    @EnvironmentObject private var bodyModels: PersonalBodyModelCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                introduction

                switch calibration.phase {
                case .idle, .preparing, .ready, .failed:
                    cameraSetup
                    controls

                case .recording:
                    liveProtocol
                    cameraPreview
                    BodyMovementSceneCard()
                    qualityCard
                    controls

                case .finalizing:
                    finalizingCard

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
        .navigationTitle("Body Calibration")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionOSSectionHeader(
                title: "Calibrate your body",
                subtitle: "40-second guided Vision geometry capture",
                systemImage: "person.crop.rectangle",
                accent: .cyan
            )

            Text(
                "MotionOS collects many full-body 3D pose frames and estimates "
                    + "stable segment geometry from their robust median. Ordinary "
                    + "workouts then animate this persistent model instead of "
                    + "rebuilding your proportions every frame."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var cameraSetup: some View {
        if camera.phase == .ready
            || camera.phase == .recording
            || camera.phase == .evidenceReady {
            cameraPreview
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Full body and both feet must remain visible.",
                    systemImage: "viewfinder"
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    "Place the iPhone on a fixed support with enough distance "
                        + "to see your head, hands, and feet throughout the sequence."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .cardStyle()
        }
    }

    private var cameraPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Camera")
                    .font(.headline)
                Spacer()
                Text(camera.phase.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(
                        camera.phase == .recording
                            ? Color.red
                            : Color.secondary
                    )
            }

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

            Text(
                "Use the camera image to keep your whole body inside frame. "
                    + "The 3D scene below is the interpreted pose output."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var liveProtocol: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            calibration.currentStep?.title
                                ?? "Finish standing tall"
                        )
                        .font(.title3.weight(.bold))

                        Text(
                            calibration.currentStep?.instruction
                                ?? "Hold still while MotionOS seals the calibration."
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
                                GuidedBodyCalibrationCoordinator
                                    .targetDurationSeconds
                                    - calibration.elapsedSeconds
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
                    value: calibration.completionFraction
                )
                .tint(.cyan)

                HStack(spacing: 6) {
                    ForEach(
                        GuidedBodyCalibrationCoordinator.steps
                    ) { step in
                        Capsule()
                            .fill(
                                step.contains(calibration.elapsedSeconds)
                                    ? Color.cyan
                                    : (
                                        calibration.elapsedSeconds
                                            >= step.endSeconds
                                            ? Color.green.opacity(0.65)
                                            : Color.secondary.opacity(0.16)
                                    )
                            )
                            .frame(height: 5)
                    }
                }
            }
            .cardStyle()
        }
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            MotionOSSectionHeader(
                title: "Geometry quality",
                subtitle: "Multi-frame calibration coverage",
                systemImage: "checkmark.circle",
                accent: calibration.canSave ? .green : .orange
            )

            HStack(spacing: 8) {
                qualityTile(
                    "SEEN",
                    "\(calibration.progress.framesSeen)"
                )
                qualityTile(
                    "COMPLETE",
                    "\(calibration.progress.acceptedFrames)"
                )
                qualityTile(
                    "ACCEPT",
                    String(
                        format: "%.0f%%",
                        calibration.progress.acceptanceFraction * 100
                    )
                )
            }

            Label(
                calibration.canSave
                    ? "Enough complete geometry has been collected."
                    : "Keep your whole body visible so every limb receives repeated samples.",
                systemImage: calibration.canSave
                    ? "checkmark.circle.fill"
                    : "viewfinder.circle"
            )
            .font(.caption)
            .foregroundStyle(
                calibration.canSave
                    ? Color.green
                    : Color.secondary
            )
        }
        .cardStyle()
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            switch calibration.phase {
            case .idle, .failed:
                Button {
                    Task {
                        await calibration.prepare(
                            camera: camera
                        )
                    }
                } label: {
                    Label(
                        "Prepare Calibration",
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
                        await calibration.start(
                            camera: camera,
                            bodyModels: bodyModels
                        )
                    }
                } label: {
                    Label(
                        "Start 40-Second Calibration",
                        systemImage: "record.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.cyan)

            case .recording:
                Button(role: .destructive) {
                    Task {
                        await calibration.finish(
                            camera: camera,
                            bodyModels: bodyModels
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
                    calibration.reset()
                } label: {
                    Label(
                        "Run Another Calibration",
                        systemImage: "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .finalizing:
                EmptyView()
            }

            if let error = calibration.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private var finalizingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Building PersonalBodyModel")
                .font(.headline)
            Text(
                "MotionOS is rejecting pose outliers, estimating stable "
                    + "segment geometry, and versioning the result."
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
        if let result = calibration.result {
            VStack(alignment: .leading, spacing: 13) {
                MotionOSSectionHeader(
                    title: "Body model saved",
                    subtitle: result.model.versionID,
                    systemImage: "checkmark.seal.fill",
                    accent: .green
                )

                HStack(spacing: 8) {
                    qualityTile(
                        "FRAMES",
                        "\(result.acceptedFrames)"
                    )
                    qualityTile(
                        "PARAMETERS",
                        "\(result.model.parameters.count)"
                    )
                    qualityTile(
                        "RIG",
                        "v1"
                    )
                }

                ForEach(
                    result.model.parameters,
                    id: \.kind
                ) { parameter in
                    HStack {
                        Text(parameterTitle(parameter.kind))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(
                            String(
                                format: "%.1f cm",
                                parameter.valueMeters * 100
                            )
                        )
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                        if let spread = parameter.uncertaintyMeters {
                            Text(
                                String(
                                    format: "±%.1f",
                                    spread * 100
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let url = calibration.modelURL {
                    ShareLink(item: url) {
                        Label(
                            "Export body model",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }

                Text(
                    "The ± values are robust frame-to-frame spread, not absolute "
                        + "anatomical accuracy. Recalibration creates a new model "
                        + "version rather than silently rewriting this one."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
    }

    private var claimBoundary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Calibration boundary",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "This calibration estimates stable skeletal segment geometry "
                    + "from Apple Vision 3D pose across many frames. It does not "
                    + "measure body fat, muscle size, force, center of mass, "
                    + "injury risk, or medical anatomy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func qualityTile(
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

    private func parameterTitle(
        _ kind: BodyParameterKind
    ) -> String {
        switch kind {
        case .standingHeight:
            return "Standing height"
        case .shoulderWidth:
            return "Shoulder width"
        case .hipWidth:
            return "Hip width"
        case .torsoLength:
            return "Torso"
        case .leftUpperArmLength:
            return "Left upper arm"
        case .rightUpperArmLength:
            return "Right upper arm"
        case .leftForearmLength:
            return "Left forearm"
        case .rightForearmLength:
            return "Right forearm"
        case .leftFemurLength:
            return "Left femur"
        case .rightFemurLength:
            return "Right femur"
        case .leftTibiaLength:
            return "Left tibia"
        case .rightTibiaLength:
            return "Right tibia"
        }
    }
}
