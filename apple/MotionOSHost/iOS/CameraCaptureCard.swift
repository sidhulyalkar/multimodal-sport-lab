import SwiftUI

struct CameraCaptureCard: View {
    @EnvironmentObject private var camera: CameraCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    "Camera + Vision 3D / P5A",
                    systemImage: "video.badge.waveform"
                )
                .font(.headline)

                Spacer()

                Text(camera.phase.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            Text(
                "Video PTS stays in its native camera clock. "
                    + "Vision pose is attached to source-frame PTS and "
                    + "mapped to Watch time only after capture."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let configuration = camera.configuration {
                configurationSummary(configuration)
            }

            controls

            if let bundle = camera.evidenceBundle {
                evidence(bundle)
            }

            if camera.phase == .denied {
                Text(
                    "Camera permission is denied or restricted. "
                        + "Enable camera access before P5A capture."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var controls: some View {
        switch camera.phase {
        case .idle, .denied, .failed:
            Button {
                Task { await camera.prepare() }
            } label: {
                Label(
                    "Authorize & Prepare Camera",
                    systemImage: "camera.badge.ellipsis"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        case .ready, .evidenceReady:
            Button {
                Task { await camera.startRecording() }
            } label: {
                Label(
                    "Start Video + Pose Evidence",
                    systemImage: "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Recording delivered camera frames and scheduled Vision pose.",
                    systemImage: "record.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)

                Text(
                    "Keep the rear camera in native landscape orientation. "
                        + "Perform deliberate sync motion near start, middle, and end."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task { await camera.stopRecording() }
                } label: {
                    Label(
                        "Stop & Seal Camera Evidence",
                        systemImage: "stop.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

        case .authorizing, .finalizing:
            HStack {
                ProgressView()
                Text(
                    camera.phase == .authorizing
                        ? "Requesting camera access…"
                        : "Closing movie, journal, and hashes…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func configurationSummary(
        _ configuration: CameraCaptureConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(configuration.localizedName)
                .font(.subheadline.weight(.semibold))
            Text(
                "\(configuration.formatWidth)×\(configuration.formatHeight) · "
                    + "rear · intrinsics "
                    + (
                        configuration.intrinsicDeliveryEnabled
                            ? "enabled"
                            : "unavailable"
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                String(
                    format: "format range %.1f–%.1f fps",
                    configuration.minFrameRate,
                    configuration.maxFrameRate
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func evidence(
        _ bundle: CameraEvidenceBundle
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Camera evidence sealed",
                systemImage: "checkmark.seal.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)

            Text(bundle.directory.lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            ShareLink(
                items: [
                    bundle.videoURL,
                    bundle.journalURL,
                    bundle.metadataURL,
                ]
            ) {
                Label(
                    "Share MOV + frame journal + metadata",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private var phaseColor: Color {
        switch camera.phase {
        case .ready, .evidenceReady:
            .green
        case .recording:
            .red
        case .authorizing, .finalizing:
            .yellow
        case .denied, .failed:
            .red
        case .idle:
            .secondary
        }
    }
}
