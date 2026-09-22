import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var coordinator: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    readiness
                    controls
                    protocolCard
                    journalCard

                    if let error = coordinator.errorMessage ?? inbox.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .navigationTitle("MotionOS")
            .toolbar {
                Button("Refresh") {
                    coordinator.refreshWatchState()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("M0-B / P0")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Apple Watch qualification")
                .font(.largeTitle.bold())
            Text("Launch the Watch workout, preserve raw wrist data locally, then recover the journal on iPhone.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Readiness", systemImage: "checklist")
                .font(.headline)

            readinessRow(
                "Watch paired",
                value: coordinator.watchPaired,
                detail: coordinator.watchPaired ? "paired" : "missing"
            )
            readinessRow(
                "Watch app",
                value: coordinator.watchAppInstalled,
                detail: coordinator.watchAppInstalled ? "installed" : "not installed"
            )
            readinessRow(
                "Reachable now",
                value: coordinator.watchReachable,
                detail: coordinator.watchReachable ? "live link" : "background path only"
            )
            HStack {
                Text("Workout state")
                Spacer()
                Text(coordinator.state.rawValue)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(stateColor)
            }
        }
        .cardStyle()
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await coordinator.requestAuthorization() }
            } label: {
                Label("Authorize HealthKit", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await coordinator.startP0() }
            } label: {
                Label("Start P0 on Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                coordinator.state == .launchingWatch
                || coordinator.state == .waitingForMirror
                || coordinator.state == .running
                || coordinator.state == .paused
            )

            Text("End the first qualification session from the Watch. Phone-side stop control comes after P0 proves mirroring and journal recovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var protocolCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("P0 field script", systemImage: "figure.walk.motion")
                .font(.headline)

            protocolRow("1", "30 s stationary baseline")
            protocolRow("2", "Rotate wrist around three axes")
            protocolRow("3", "Three deliberate sync impulses")
            protocolRow("4", "Walk for two minutes")
            protocolRow("5", "Lock/background the phone")
            protocolRow("6", "Temporarily separate phone and Watch")
            protocolRow("7", "Reconnect and stop from Watch")
            protocolRow("8", "Confirm journal arrives below")
        }
        .cardStyle()
    }

    private var journalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovered Watch journal", systemImage: "internaldrive")
                .font(.headline)

            if let sessionID = inbox.latestSessionID,
               let url = inbox.latestJournalURL {
                Text(sessionID)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Copied into iPhone Documents", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("No journal received yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func readinessRow(_ title: String, value: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: value ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(value ? .green : .yellow)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func protocolRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.thinMaterial, in: Circle())
            Text(text)
                .font(.subheadline)
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .running: .green
        case .paused, .waitingForMirror, .launchingWatch, .authorizing: .yellow
        case .failed, .disconnected: .red
        default: .secondary
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
