import SwiftUI

struct SensorSourceStrip: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox
    @EnvironmentObject private var pod: EquipmentPodController
    @EnvironmentObject private var camera: CameraCaptureController

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                sourceCard(
                    title: "Watch",
                    detail: watchDetail,
                    symbol: "applewatch",
                    color: watchColor
                )

                sourceCard(
                    title: "Equipment",
                    detail: pod.phase.rawValue.capitalized,
                    symbol: "sensor.tag.radiowaves.forward",
                    color: podColor
                )

                sourceCard(
                    title: "Camera",
                    detail: camera.phase.rawValue.capitalized,
                    symbol: "video.fill",
                    color: cameraColor
                )

                sourceCard(
                    title: "Evidence",
                    detail: inbox.latestSessionID == nil
                        ? "Awaiting"
                        : "Verified",
                    symbol: "checkmark.seal",
                    color: inbox.latestSessionID == nil
                        ? .secondary
                        : .green
                )
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("MotionOS source status")
    }

    private func sourceCard(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(color.opacity(0.10), lineWidth: 1)
        }
    }

    private var watchDetail: String {
        if phone.state == .running || phone.state == .paused {
            return "Recording"
        }
        return phone.watchConnectionDetail
    }

    private var watchColor: Color {
        if phone.watchConnectionReady {
            return .green
        }
        return phone.watchPaired ? .yellow : .secondary
    }

    private var podColor: Color {
        switch pod.phase {
        case .ready, .evidenceReady:
            .green
        case .previewing, .recording:
            .cyan
        case .scanning, .connecting, .recovering, .downloading:
            .yellow
        case .linkLost, .failed:
            .red
        default:
            .secondary
        }
    }

    private var cameraColor: Color {
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
