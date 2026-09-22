import SwiftUI

struct CameraEvidenceCard: View {
    @EnvironmentObject private var camera: PhoneCameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Camera + Vision evidence", systemImage: "video.badge.waveform")
                    .font(.headline)
                Spacer()
                Text(camera.state.rawValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(stateColor)
            }

            HStack {
                readiness(
                    "Camera",
                    ready: camera.cameraAuthorized,
                    detail: camera.cameraAuthorized ? "authorized" : "permission needed"
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(camera.frameCount) frames")
                    Text("\(camera.poseCount) poses")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(
                "Field mode: fixed back camera, landscape-right tripod view, " +
                "video-frame PTS as the raw camera clock, Vision 3D pose sampled " +
                "at a lower analysis rate."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            CameraPreview(session: camera.previewSession)
                .frame(height: 210)
                .background(.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if camera.cameraAuthorized
                && camera.state != .recording
                && camera.state != .starting
                && camera.state != .stopping {
                Button {
                    camera.preparePreview()
                } label: {
                    Label("Prepare / Refresh Preview", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await camera.requestAuthorization() }
            } label: {
                Label("Authorize Camera", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(camera.state == .authorizing)

            if camera.state == .previewing {
                Button {
                    camera.stopPreview()
                } label: {
                    Label("Stop Preview", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if camera.state == .recording || camera.state == .starting {
                Button(role: .destructive) {
                    camera.stopEvidenceCapture()
                } label: {
                    Label("Stop Camera Evidence", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    camera.startEvidenceCapture()
                } label: {
                    Label("Start Camera Evidence", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!camera.cameraAuthorized || camera.state == .stopping)
            }

            if let video = camera.latestVideoURL,
               let journal = camera.latestJournalURL,
               let metadata = camera.latestMetadataURL {
                Divider()
                Label("Closed evidence bundle", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text(video.deletingLastPathComponent().lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                ShareLink(items: [video, journal, metadata]) {
                    Label(
                        "Share video + camera evidence",
                        systemImage: "square.and.arrow.up"
                    )
                }
            }

            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private func readiness(
        _ title: String,
        ready: Bool,
        detail: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? .green : .yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateColor: Color {
        switch camera.state {
        case .recording:
            .green
        case .authorizing, .configuring, .previewing, .starting, .stopping:
            .yellow
        case .failed:
            .red
        default:
            .secondary
        }
    }
}
