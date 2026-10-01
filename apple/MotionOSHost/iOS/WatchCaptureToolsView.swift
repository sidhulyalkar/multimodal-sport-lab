import SwiftUI

struct WatchCaptureToolsView: View {
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MotionOSDesign.pageSpacing) {
                header
                readiness
                controls
                GuidedP0Card()

                if inbox.latestSessionID != nil {
                    SessionLensCard()
                }
            }
            .motionOSPageWidth()
            .padding(.horizontal, MotionOSDesign.pageHorizontalPadding)
            .padding(.vertical, 12)
        }
        .background {
            MotionOSPageBackground()
        }
        .navigationTitle("Watch Capture")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            phone.refreshWatchState()
            phone.refreshHostReadiness()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            MotionOSSectionHeader(
                title: "Apple Watch capture",
                subtitle: "Qualification, Sensor Check, and raw wrist evidence",
                systemImage: "applewatch.radiowaves.left.and.right",
                accent: .indigo
            )

            Text(
                "Use the Watch-local Sensor Check for an isolated substrate "
                    + "test, or launch the mirrored capture here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var readiness: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let observation = phone.observation(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    "Apple Watch",
                    observation.link.isReady,
                    observation.link.title
                )
                statusRow(
                    "Live view",
                    observation.observatory.isLive,
                    observation.observatory.badge.capitalized
                )

                if let snapshot = observation.sessionFrame?.snapshot {
                    HStack(spacing: 8) {
                        metric(
                            "IMU",
                            snapshot.recentMedianIMUHz.map {
                                String(format: "%.1f Hz", $0)
                            } ?? "—"
                        )
                        metric(
                            "HR",
                            observation.observatory.isLive
                                ? snapshot.heartRateBPM.map {
                                    "\(Int($0.rounded()))"
                                } ?? "—"
                                : "—"
                        )
                        metric(
                            "gap",
                            String(format: "%.0f ms", snapshot.maxIMUGapMS)
                        )
                    }
                }
            }
            .cardStyle()
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await phone.startP0() }
            } label: {
                Label(
                    "Start Watch Capture",
                    systemImage: "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                !phone.watchPaired
                    || !phone.watchAppInstalled
                    || phone.state == .running
                    || phone.state == .paused
                    || phone.state == .launchingWatch
                    || phone.state == .waitingForMirror
            )

            Button {
                Task { await phone.requestAuthorization() }
            } label: {
                Label(
                    "Authorize HealthKit",
                    systemImage: "heart.text.square"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text(
                "For qualification runs, follow the guided protocol and preserve "
                    + "the resulting Watch journal. The production Indo Board "
                    + "workflow can finish the Watch remotely through the same "
                    + "deterministic stop path."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func statusRow(
        _ title: String,
        _ ready: Bool,
        _ detail: String
    ) -> some View {
        HStack {
            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(ready ? .green : .yellow)
            Text(title)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
