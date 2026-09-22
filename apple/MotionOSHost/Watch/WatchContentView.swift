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
            } else if controller.state == .transferred {
                Label("Journal queued", systemImage: "checkmark.circle.fill")
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
            if let bpm = controller.heartRateBPM {
                Text("\(Int(bpm.rounded())) BPM")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            } else {
                Text("HR …")
                    .foregroundStyle(.secondary)
            }

            Text("\(controller.eventCount) events")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let start = controller.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(duration(from: start, to: context.date))
                        .font(.system(.caption, design: .monospaced))
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
        case .paused, .starting, .ending, .authorizing: .yellow
        case .failed: .red
        default: .gray
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
