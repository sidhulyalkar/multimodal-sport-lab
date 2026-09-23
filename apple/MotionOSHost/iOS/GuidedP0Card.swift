import MotionOSAppleCapture
import SwiftUI

struct GuidedP0Card: View {
    @EnvironmentObject private var guided: GuidedP0Controller
    @EnvironmentObject private var phone: PhoneSessionCoordinator
    @EnvironmentObject private var inbox: PhoneJournalInbox

    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch guided.progress.state {
            case .idle:
                configuration
                preflight
                launchControls

            case .running:
                runningProtocol

            case .completed:
                finished(
                    title: "Guided protocol complete",
                    color: .green,
                    symbol: "checkmark.circle.fill"
                )

            case .cancelled:
                finished(
                    title: "Guided protocol cancelled",
                    color: .yellow,
                    symbol: "exclamationmark.circle"
                )
            }

            if let error = guided.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(
                "Guidance events are operator annotations only. "
                    + "Watch haptic/step cues are best-effort when reachable. "
                    + "Watch device timestamps and the sealed Watch journal "
                    + "remain the P0 evidence authority."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
        .confirmationDialog(
            "Cancel guided protocol?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel Protocol", role: .destructive) {
                guided.cancel()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text(
                "The guidance journal will record the cancellation. "
                    + "This does not stop the Watch workout."
            )
        }
    }

    private var header: some View {
        HStack {
            Label(
                "Guided Watch qualification",
                systemImage: "list.clipboard.fill"
            )
            .font(.headline)

            Spacer()

            Text(guided.mode.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Protocol",
                selection: Binding(
                    get: { guided.mode },
                    set: { guided.selectMode($0) }
                )
            ) {
                ForEach(GuidedP0Controller.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(guided.plan.title)
                .font(.subheadline.weight(.semibold))

            Text(
                guided.mode == .p0A
                    ? "10-minute real-device shakedown before external sensors."
                    : "30-minute qualification after P0-A passes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Preflight")
                .font(.subheadline.weight(.semibold))

            preflightRow(
                "Watch paired",
                ready: phone.watchPaired,
                value: phone.watchPaired ? "yes" : "no"
            )
            preflightRow(
                "Watch app",
                ready: phone.watchAppInstalled,
                value: phone.watchAppInstalled ? "installed" : "missing"
            )
            preflightRow(
                "iPhone battery",
                ready: (phone.iPhoneBatteryLevel ?? 0) >= 0.20,
                value: phone.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "unknown"
            )
            preflightRow(
                "Free storage",
                ready: (phone.iPhoneAvailableStorageBytes ?? 0)
                    >= 5_000_000_000,
                value: phone.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "unknown"
            )
        }
    }

    @ViewBuilder
    private var launchControls: some View {
        if phone.state == .running || phone.state == .paused {
            Label(
                "Watch workout is active",
                systemImage: "applewatch.radiowaves.left.and.right"
            )
            .font(.caption)
            .foregroundStyle(.green)

            Button {
                guided.start()
                sendCurrentStepCue()
            } label: {
                Label(
                    "Begin \(guided.mode.rawValue) Guidance",
                    systemImage: "play.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                Task { await phone.startP0() }
            } label: {
                Label(
                    "Launch Watch Capture",
                    systemImage: "applewatch.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !phone.watchPaired
                    || !phone.watchAppInstalled
                    || phone.state == .launchingWatch
                    || phone.state == .waitingForMirror
            )

            Text(
                "Guidance becomes available after the mirrored Watch workout "
                    + "is actually running."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var runningProtocol: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                progressHeader

                if let step = guided.currentStep {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(step.title)
                            .font(.title3.weight(.semibold))
                        Text(step.instruction)
                            .font(.subheadline)
                    }

                    gateStatus(step: step)

                    Button {
                        guided.completeCurrentStep()
                        sendCurrentStepCue()
                    } label: {
                        Label(
                            guided.currentStepCanComplete()
                                ? "Complete Step"
                                : "Minimum Time Not Reached",
                            systemImage: guided.currentStepCanComplete()
                                ? "checkmark.circle.fill"
                                : "timer"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!guided.currentStepCanComplete())

                    if step.allowsSkip {
                        Button {
                            guided.skipCurrentStep()
                            sendCurrentStepCue()
                        } label: {
                            Label(
                                "Skip & Record Skip",
                                systemImage: "forward.end"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label(
                        "Cancel Guidance",
                        systemImage: "xmark.circle"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var progressHeader: some View {
        let completed = guided.progress.completedStepIDs.count
        let skipped = guided.progress.skippedStepIDs.count
        let total = guided.plan.steps.count
        let finished = min(total, completed + skipped)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(
                    "Step \(min(finished + 1, total)) of \(total)"
                )
                .font(.caption.weight(.semibold))

                Spacer()

                Text(duration(guided.planElapsedSeconds()))
                    .font(.system(.caption, design: .monospaced))
            }

            ProgressView(
                value: Double(finished),
                total: Double(total)
            )

            HStack {
                Text("\(completed) complete")
                if skipped > 0 {
                    Text("· \(skipped) skipped")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func gateStatus(
        step: GuidedProtocolStep
    ) -> some View {
        let remaining = guided.remainingGateSeconds()

        return VStack(alignment: .leading, spacing: 3) {
            if remaining > 0 {
                Label(
                    "\(duration(remaining)) minimum remaining",
                    systemImage: "timer"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            } else {
                Label(
                    "Minimum timing requirement satisfied",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

            if step.minimumPlanElapsedSeconds != nil {
                Text(
                    "This gate uses monotonic total protocol time, "
                        + "not only time on the current screen."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func finished(
        title: String,
        color: Color,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)

            Text(
                "\(guided.progress.completedStepIDs.count) completed · "
                    + "\(guided.progress.skippedStepIDs.count) skipped"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let bundle = guided.evidenceBundle {
                ShareLink(item: bundle.journalURL) {
                    Label(
                        "Share guidance journal",
                        systemImage: "square.and.arrow.up"
                    )
                }
            }

            if let sessionID = inbox.latestSessionID {
                Label(
                    "Latest Watch evidence: \(sessionID)",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
            } else {
                Text(
                    "Guidance completion does not mean the Watch journal "
                        + "has been recovered yet."
                )
                .font(.caption2)
                .foregroundStyle(.yellow)
            }

            Button("Reset Guidance") {
                guided.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    private func sendCurrentStepCue() {
        guard guided.isRunning,
              let step = guided.currentStep
        else {
            return
        }

        _ = phone.sendGuidedProtocolCue(
            plan: guided.plan,
            step: step
        )
    }

    private func preflightRow(
        _ title: String,
        ready: Bool,
        value: String
    ) -> some View {
        HStack {
            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(ready ? .green : .yellow)

            Text(title)
                .font(.caption)

            Spacer()

            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func duration(
        _ seconds: TimeInterval
    ) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return String(
            format: "%02d:%02d",
            value / 60,
            value % 60
        )
    }
}
