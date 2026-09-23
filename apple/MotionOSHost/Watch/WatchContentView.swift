import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var controller: WatchSessionController

    var body: some View {
        VStack(spacing: 10) {
            Text("MotionOS")
                .font(.headline)

            statusView

            if controller.state == .running || controller.state == .paused {
                metrics
                controls
            } else if controller.state == .idle {
                Button("Enable Health") {
                    Task { await controller.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)

                Text("Start P0 from the paired iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if controller.state == .journalReady {
                Label("Journal safe on Watch", systemImage: "internaldrive.fill")
                    .foregroundStyle(.yellow)
                Button("Retry Transfer") {
                    controller.retryTransfer()
                }
                .buttonStyle(.borderedProminent)
            } else if controller.state == .transferQueued {
                Label("Transfer queued", systemImage: "arrow.up.doc.fill")
                    .foregroundStyle(.yellow)
                Text("Journal remains safe locally.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if controller.state == .transportComplete {
                Label("Sent to iPhone", systemImage: "iphone.and.arrow.forward")
                    .foregroundStyle(.yellow)
                Text("Waiting for hash-verified receipt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry if needed") {
                    controller.retryTransfer()
                }
                .buttonStyle(.bordered)
            } else if controller.state == .transferred {
                Label("Verified on iPhone", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(controller.sessionID ?? "")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var statusView: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(controller.state.rawValue.uppercased())
                .font(.caption2.weight(.semibold))
        }
    }

    private var metrics: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let bpm = controller.heartRateBPM {
                    Text("\(Int(bpm.rounded())) BPM")
                        .font(
                            .system(.caption, design: .rounded)
                                .weight(.semibold)
                        )
                } else {
                    Text("HR …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let hz = controller.recentMedianIMUHz {
                    Text(String(format: "%.1f Hz", hz))
                        .font(
                            .system(.caption, design: .monospaced)
                                .weight(.semibold)
                        )
                } else {
                    Text("Hz …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "\(controller.imuSampleCount) IMU · "
                    + "\(controller.heartRateEventCount) HR"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(
                String(
                    format: "max gap %.0f ms",
                    controller.maxIMUGapMS
                )
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(
                controller.nonMonotonicIMUCount == 0
                    ? Color.secondary
                    : Color.red
            )

            if let start = controller.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text(duration(from: start, to: context.date))
                        if let last = controller.lastIMUSampleReceivedAt {
                            let age = max(
                                0,
                                context.date.timeIntervalSince(last)
                            )
                            Text(
                                age < 2
                                    ? "LIVE"
                                    : String(format: "STALE %.0fs", age)
                            )
                            .foregroundStyle(age < 2 ? .green : .red)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            if controller.state == .running {
                Button {
                    controller.pause()
                } label: {
                    Image(systemName: "pause.fill")
                }
            } else {
                Button {
                    controller.resume()
                } label: {
                    Image(systemName: "play.fill")
                }
            }

            Button(role: .destructive) {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
        }
        .buttonStyle(.bordered)
    }

    private var statusColor: Color {
        switch controller.state {
        case .running: .green
        case .paused, .starting, .ending, .authorizing,
                .transferQueued, .transportComplete:
            .yellow
        case .transferred:
            .green
        case .failed:
            .red
        default:
            .gray
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
