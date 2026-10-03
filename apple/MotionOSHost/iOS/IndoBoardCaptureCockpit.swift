import Charts
import MotionOSAppleCapture
import SwiftUI

struct IndoBoardFramingCard: View {
    @EnvironmentObject private var camera: CameraCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionOSSectionHeader(
                title: "Framing",
                subtitle: "Keep your full body, feet, and board inside the guide",
                systemImage: "viewfinder",
                accent: .cyan
            )

            ZStack {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .fill(Color.black)

                if camera.phase == .ready
                    || camera.phase == .recording
                    || camera.phase == .evidenceReady {
                    CameraPreviewView(
                        session: camera.previewSession
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 20,
                            style: .continuous
                        )
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.65))
                        Text("Prepare camera to preview framing")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height

                    RoundedRectangle(
                        cornerRadius: 28,
                        style: .continuous
                    )
                    .stroke(
                        Color.white.opacity(0.62),
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            dash: [7, 6]
                        )
                    )
                    .frame(
                        width: width * 0.55,
                        height: height * 0.78
                    )
                    .position(
                        x: width * 0.50,
                        y: height * 0.47
                    )

                    Capsule()
                        .fill(Color.cyan.opacity(0.78))
                        .frame(
                            width: width * 0.50,
                            height: 2
                        )
                        .position(
                            x: width * 0.50,
                            y: height * 0.83
                        )

                    Text("BOARD")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.cyan)
                        .position(
                            x: width * 0.50,
                            y: height * 0.87
                        )
                }
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        Spacer()
                        Text(cameraStatus)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                .black.opacity(0.55),
                                in: Capsule()
                            )
                    }
                    Spacer()
                }
                .padding(10)
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            if let stats = camera.liveStats {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        framingMetric(
                            "FPS",
                            stats.effectiveDeliveredFPS.map {
                                String(format: "%.1f", $0)
                            } ?? "—"
                        )
                        framingMetric(
                            "Written",
                            "\(stats.writtenFrames)"
                        )
                        framingMetric(
                            "Drops",
                            "\(stats.droppedFrames)"
                        )
                        framingMetric(
                            "Pose",
                            stats.poseSuccessFraction.map {
                                String(format: "%.0f%%", $0 * 100)
                            } ?? "—"
                        )
                    }

                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 8,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            framingMetric(
                                "FPS",
                                stats.effectiveDeliveredFPS.map {
                                    String(format: "%.1f", $0)
                                } ?? "—"
                            )
                            framingMetric(
                                "Drops",
                                "\(stats.droppedFrames)"
                            )
                        }
                        GridRow {
                            framingMetric(
                                "Written",
                                "\(stats.writtenFrames)"
                            )
                            framingMetric(
                                "Pose",
                                stats.poseSuccessFraction.map {
                                    String(format: "%.0f%%", $0 * 100)
                                } ?? "—"
                            )
                        }
                    }
                }
            }

            Text(
                "The guide is for operator framing only. It does not certify "
                    + "pose quality, calibration, or board geometry."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var cameraStatus: String {
        switch camera.phase {
        case .recording:
            "● RECORDING"
        case .ready:
            "READY"
        case .evidenceReady:
            "SEALED"
        case .authorizing:
            "AUTHORIZING"
        case .finalizing:
            "SEALING"
        case .denied:
            "DENIED"
        case .failed:
            "CHECK"
        case .idle:
            "OFF"
        }
    }

    private func framingMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
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

/// The live Watch signal inside the capture workspace. Same model and
/// rendering as the Observe tab, so the two can never disagree about LIVE.
struct IndoBoardLiveSignalCard: View {
    @EnvironmentObject private var camera:
        CameraCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveObservatoryView(style: .embedded)

            if let primitive = camera.latestIndoPrimitive {
                HStack(spacing: 8) {
                    Image(systemName: primitiveSymbol(primitive.kind))
                        .foregroundStyle(.cyan)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("VISION BEHAVIOR")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(primitiveTitle(primitive.kind))
                            .font(.subheadline.weight(.semibold))
                    }

                    Spacer()

                    Text(
                        "\(Int((primitive.confidence * 100).rounded()))%"
                    )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                if let state =
                        camera.latestPoseFrame?
                            .indoBoardBalanceState {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            boardMetric(
                                "ROLLER",
                                rollerPositionLabel(state)
                            )
                            boardMetric(
                                "CENTER",
                                "\(Int((state.centerProximity * 100).rounded()))%"
                            )
                            boardMetric(
                                "EVIDENCE",
                                "\(Int((state.confidence * 100).rounded()))%"
                            )
                        }

                        Label(
                            boardEvidenceLabel(state.provenance),
                            systemImage: "viewfinder.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                    }
                } else {
                    Label(
                        "Body-pose proxy · board tracking not available",
                        systemImage: "figure.stand"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func boardMetric(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        .caption,
                        design: .monospaced,
                        weight: .semibold
                    )
                )
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.green.opacity(0.07),
            in: RoundedRectangle(
                cornerRadius: 9,
                style: .continuous
            )
        )
    }

    private func rollerPositionLabel(
        _ state: IndoBoardBalanceState
    ) -> String {
        let value = state.rollerAlongDeck
        if abs(value) <= IndoBoardBalanceThresholds.centerZone {
            return "CENTER"
        }
        return String(
            format: "%@ %.2f",
            value < 0 ? "L" : "R",
            abs(value)
        )
    }

    private func boardEvidenceLabel(
        _ provenance: IndoBoardEquipmentProvenance
    ) -> String {
        switch provenance {
        case .fiducialMeasured:
            return "Body pose + QR deck/roller geometry"
        case .manualAnnotated:
            return "Body pose + reviewed deck/roller geometry"
        case .modelEstimated:
            return "Body pose + model-estimated deck/roller geometry"
        case .geometricProxy:
            return "Body pose + deck/roller geometric proxy"
        }
    }

    private func primitiveTitle(
        _ kind: IndoBoardPrimitiveKind
    ) -> String {
        switch kind {
        case .neutralStance:
            "Neutral stance"
        case .lateralShiftLeft:
            "Left shift"
        case .lateralShiftRight:
            "Right shift"
        case .partialSquat:
            "Partial squat"
        case .singleLegCandidate:
            "Single-leg candidate"
        case .largeArmRecovery:
            "Large arm recovery"
        case .unknown:
            "Unclassified movement"
        }
    }

    private func primitiveSymbol(
        _ kind: IndoBoardPrimitiveKind
    ) -> String {
        switch kind {
        case .neutralStance:
            "figure.stand"
        case .lateralShiftLeft:
            "arrow.left"
        case .lateralShiftRight:
            "arrow.right"
        case .partialSquat:
            "figure.strengthtraining.traditional"
        case .singleLegCandidate:
            "figure.cooldown"
        case .largeArmRecovery:
            "figure.mixed.cardio"
        case .unknown:
            "questionmark.circle"
        }
    }
}

struct IndoBoardProtocolRibbon: View {
    @EnvironmentObject private var fieldRun: FieldRunCoordinator
    @EnvironmentObject private var session: IndoBoardSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("SESSION TIMELINE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    "\(Int(min(120, session.elapsedSeconds))) / 120 s"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let elapsedFraction = min(
                    1,
                    session.elapsedSeconds
                        / IndoBoardSessionCoordinator
                            .targetDurationSeconds
                )

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(8, width * elapsedFraction),
                            height: 8
                        )

                    let markerFractions: [CGFloat] = [
                        15.0 / 120.0,
                        35.0 / 120.0,
                        60.0 / 120.0,
                        85.0 / 120.0,
                        105.0 / 120.0,
                    ]

                    ForEach(markerFractions, id: \.self) { marker in
                        let offsetX = max(
                            CGFloat.zero,
                            min(
                                width - 9,
                                width * marker - 4.5
                            )
                        )

                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color(.systemBackground),
                                        lineWidth: 2
                                    )
                            }
                            .offset(x: offsetX)
                    }
                }
            }
            .frame(height: 10)

            HStack {
                Text("settle")
                Spacer()
                Text("balance")
                Spacer()
                Text("shifts")
                Spacer()
                Text("squats")
                Spacer()
                Text("finish")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
        )
    }
}
