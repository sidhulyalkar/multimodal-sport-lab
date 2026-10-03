import MotionOSAppleCapture
import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var controller: WatchSessionController
    @State private var confirmStop = false
    @State private var confirmDelete = false
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                brandHeader

                if isCaptureActive {
                    captureDashboard
                } else {
                    indoBoardRemoteCard
                    readinessCard
                    stateCard
                }

                if let error = controller.errorMessage {
                    errorCard(error)
                }

                detailsSection
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 8)
        }
        .confirmationDialog(
            "End this capture?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("End Capture", role: .destructive) {
                controller.stop()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("MotionOS will seal the Watch journal before transfer.")
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                _ = controller.deleteCurrentRecording()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text(
                "MotionOS will cancel the queued transfer when possible and "
                    + "delete this Watch copy. If the iPhone already received "
                    + "it, delete that copy from Sessions."
            )
        }
        .task {
            while !Task.isCancelled {
                controller.refreshReadinessAndPresence()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                statusColor.opacity(0.28),
                                Color.cyan.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Circle()
                    .stroke(statusColor.opacity(0.24), lineWidth: 1)
                    .frame(width: 36, height: 36)

                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MotionOS")
                    .font(.headline)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Idle answers only: ready? iPhone? Health? Can I record?
    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            readinessRow(
                title: "iPhone",
                value: phoneLinked ? "Ready" : "Open app",
                symbol: "iphone",
                ready: phoneLinked
            )

            readinessRow(
                title: "Health",
                value: controller.healthAccessReady ? "On" : "Off",
                symbol: "heart.fill",
                ready: controller.healthAccessReady
            )

            if let battery = controller.watchBatteryLevel, battery < 0.20 {
                readinessRow(
                    title: "Battery",
                    value: String(format: "%.0f%%", battery * 100),
                    symbol: "battery.25percent",
                    ready: false
                )
            }

            if controller.pendingTransferCount > 0 {
                readinessRow(
                    title: "Syncing",
                    value: controller.pendingTransferCount == 1
                        ? "1 recording"
                        : "\(controller.pendingTransferCount) recordings",
                    symbol: "arrow.up.doc",
                    ready: true
                )
            }

            if !controller.healthAccessReady {
                Button {
                    Task { await controller.requestAuthorization() }
                } label: {
                    Label("Enable Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
        }
        .panelStyle()
    }

    private var indoBoardRemoteCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "figure.surfing")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Indo Board")
                        .font(.subheadline.weight(.semibold))
                    Text("Camera setup + session control")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !controller.phoneReachable {
                remoteInstruction(
                    title: "Open MotionOS on iPhone",
                    detail:
                        "Leave the iPhone app open with the camera aimed at the board. Then use the Watch from here.",
                    symbol: "iphone.slash",
                    color: .yellow
                )
            } else if let status = controller.indoRemoteStatus {
                indoRemoteStatusContent(status)
            } else {
                remoteInstruction(
                    title: "Connecting to camera",
                    detail:
                        "MotionOS is asking the iPhone for the current setup state.",
                    symbol: "arrow.triangle.2.circlepath",
                    color: .secondary
                )

                Button {
                    controller.requestIndoRemoteStatus()
                } label: {
                    Label("Check iPhone", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let message = controller.indoRemoteErrorMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private func indoRemoteStatusContent(
        _ status: IndoBoardRemoteStatus
    ) -> some View {
        let phase = status.sessionPhase.lowercased()

        if phase == "starting" || phase == "preparing" {
            remoteInstruction(
                title: "Arming sensors",
                detail:
                    "Stay on the board. MotionOS is opening the Watch journal and iPhone video together.",
                symbol: "hourglass",
                color: .yellow
            )
        } else if phase == "countdown" {
            countdownPanel(status.countdownRemaining ?? 1)
        } else if phase == "finishing" || phase == "watchstoprequired" {
            remoteInstruction(
                title: "Saving session",
                detail:
                    status.startBlocker
                        ?? "MotionOS is sealing video and Watch evidence.",
                symbol: "lock.doc",
                color: .yellow
            )
        } else if phase == "sealed" {
            if let headline = status.coachHeadline,
               let tip = status.coachTip,
               let drill = status.coachDrill {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.mind.and.body")
                            .foregroundStyle(.cyan)
                        Text("COACH")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let confidence =
                            status.coachConfidencePercent {
                            Text("\(confidence)%")
                                .font(
                                    .system(
                                        size: 9,
                                        design: .monospaced
                                    )
                                )
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(headline)
                        .font(.headline)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                    Text(tip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                    if let summary =
                            status.coachExperimentSummary {
                        Label(
                            coachExperimentTitle(
                                status.coachExperimentOutcome
                            ),
                            systemImage: coachExperimentSymbol(
                                status.coachExperimentOutcome
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            coachExperimentColor(
                                status.coachExperimentOutcome
                            )
                        )

                        Text(summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }

                    Divider()

                    Label(drill, systemImage: "repeat")
                        .font(.caption.weight(.semibold))
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                    if let evidence = status.coachEvidenceLabel {
                        Text(evidence)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }
            } else {
                remoteInstruction(
                    title: "Session saved",
                    detail:
                        "Your camera and Watch evidence are sealed. MotionOS needs a cleaner pose capture before giving a coaching cue.",
                    symbol: "checkmark.seal.fill",
                    color: .green
                )
            }

            Button {
                _ = controller.sendIndoRemoteCommand(.resetSession)
            } label: {
                Label(
                    status.coachDrill == nil
                        ? "Next Session"
                        : "Repeat & Test Cue",
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(controller.indoRemoteCommandPending)
        } else if status.cameraPhase.lowercased() != "ready" {
            remoteInstruction(
                title: cameraSetupTitle(status),
                detail: cameraSetupDetail(status),
                symbol: "camera.viewfinder",
                color: .cyan
            )

            Button {
                _ = controller.sendIndoRemoteCommand(.prepareCamera)
            } label: {
                Label(
                    controller.indoRemoteCommandPending
                        ? "Starting Camera…"
                        : "Set Up Camera",
                    systemImage: "camera.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(controller.indoRemoteCommandPending)
        } else if !status.framingReady {
            HStack(spacing: 8) {
                Image(systemName: remoteFramingSymbol(status))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(remoteFramingColor(status))

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.framingTitle)
                        .font(.caption.weight(.semibold))
                    Text("\(status.framingScore)% framing")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(status.framingInstruction)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if status.stanceState.lowercased() != "stable" {
            HStack(spacing: 7) {
                Image(systemName: "figure.stand")
                    .foregroundStyle(.cyan)
                Text(status.stanceTitle)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(status.stanceProgressPercent)%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(status.stanceProgressPercent),
                total: 100
            )
            .tint(.cyan)

            Text(
                status.startBlocker
                    ?? "Hold a comfortable neutral stance for about two seconds."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if status.startReady {
            VStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Ready to start?")
                    .font(.headline)
                Text("Camera locked · stance stable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                boardTrackingBadge(status)
            }
            .frame(maxWidth: .infinity)

            Button {
                _ = controller.sendIndoRemoteCommand(.startSession)
            } label: {
                Label(
                    controller.indoRemoteCommandPending
                        ? "Arming…"
                        : "Start",
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(controller.indoRemoteCommandPending)

            Text(
                "MotionOS captures a short pre-roll, then gives a 5-second haptic countdown before the protocol clock starts."
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if let blocker = status.startBlocker {
            remoteInstruction(
                title: "One thing left",
                detail: blocker,
                symbol: "exclamationmark.circle",
                color: .yellow
            )
        }
    }

    @ViewBuilder
    private func boardTrackingBadge(
        _ status: IndoBoardRemoteStatus
    ) -> some View {
        let coverage =
            status.boardTrackingCoveragePercent ?? 0
        let hasIntermittentEvidence = coverage > 0
        let title =
            status.boardTrackingReady
                ? "Board + roller stable"
                : (
                    hasIntermittentEvidence
                        ? "Board markers intermittent"
                        : "Body-only beta mode"
                )
        let symbol =
            status.boardTrackingReady
                ? "viewfinder.circle.fill"
                : (
                    hasIntermittentEvidence
                        ? "viewfinder.circle"
                        : "figure.stand"
                )
        let accent: Color =
            status.boardTrackingReady
                ? .green
                : (
                    hasIntermittentEvidence
                        ? .yellow
                        : .secondary
                )

        Label(
            title,
            systemImage: symbol
        )
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(accent)

        if hasIntermittentEvidence {
            let confidence =
                status.boardTrackingConfidencePercent
            Text(
                confidence.map {
                    "\(coverage)% visible · \($0)% confidence"
                }
                ?? "\(coverage)% visible"
            )
            .font(
                .system(
                    size: 8,
                    design: .monospaced
                )
            )
            .foregroundStyle(.tertiary)
        }
    }

    private func countdownPanel(
        _ remaining: Int
    ) -> some View {
        VStack(spacing: 3) {
            Text("GET READY")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)

            Text("\(max(1, remaining))")
                .font(
                    .system(
                        size: 48,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .monospacedDigit()

            Text("Settle into your natural stance")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func remoteInstruction(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cameraSetupTitle(
        _ status: IndoBoardRemoteStatus
    ) -> String {
        switch status.cameraPhase.lowercased() {
        case "authorizing":
            return "Allow camera on iPhone"
        case "denied":
            return "Camera permission needed"
        case "failed":
            return "Camera needs attention"
        case "evidence ready":
            return "Ready for another setup"
        default:
            return "Set up the iPhone camera"
        }
    }

    private func cameraSetupDetail(
        _ status: IndoBoardRemoteStatus
    ) -> String {
        status.startBlocker
            ?? "Start the camera preview, then walk into frame. The Watch will tell you how to adjust."
    }

    private func coachExperimentTitle(
        _ outcome: String?
    ) -> String {
        switch outcome {
        case "improved":
            return "Cue moved the target"
        case "opposite_direction":
            return "Cue moved the wrong way"
        case "no_clear_change":
            return "No clear cue effect yet"
        default:
            return "Cue effect not scored"
        }
    }

    private func coachExperimentSymbol(
        _ outcome: String?
    ) -> String {
        switch outcome {
        case "improved":
            return "checkmark.circle.fill"
        case "opposite_direction":
            return "arrow.uturn.backward.circle"
        case "no_clear_change":
            return "equal.circle"
        default:
            return "questionmark.circle"
        }
    }

    private func coachExperimentColor(
        _ outcome: String?
    ) -> Color {
        switch outcome {
        case "improved":
            return .green
        case "opposite_direction":
            return .orange
        default:
            return .secondary
        }
    }

    private func remoteFramingColor(
        _ status: IndoBoardRemoteStatus
    ) -> Color {
        switch status.framingState.lowercased() {
        case "ready":
            return .green
        case "adjust":
            return .yellow
        default:
            return .secondary
        }
    }

    private func remoteFramingSymbol(
        _ status: IndoBoardRemoteStatus
    ) -> String {
        switch status.framingState.lowercased() {
        case "ready":
            return "checkmark.circle.fill"
        case "adjust":
            return "viewfinder.circle"
        default:
            return "person.crop.rectangle"
        }
    }

    private var phoneLinked: Bool {
        controller.companionAppInstalled
            || controller.phonePresenceConfirmed
            || controller.phoneReachable
    }

    @ViewBuilder
    private var stateCard: some View {
        switch controller.state {
        case .idle:
            EmptyView()

        case .authorizing:
            progressPanel(
                title: "Authorizing Health",
                detail: "Complete the Health permission sheet on this Watch.",
                symbol: "heart.text.square"
            )

        case .starting:
            progressPanel(
                title: "Starting capture",
                detail: "Opening the workout, journal, and motion stream.",
                symbol: "waveform.path.ecg"
            )

        case .ending:
            progressPanel(
                title: "Sealing journal",
                detail: "Finishing accepted samples before the file closes.",
                symbol: "lock.doc"
            )

        case .journalReady:
            completedCapturePanel(
                title: "Recording saved",
                detail: "Safe on this Watch. MotionOS will retry the iPhone sync automatically.",
                symbol: "internaldrive.fill",
                showRetry: true,
                canDelete: true
            )

        case .transferQueued:
            completedCapturePanel(
                title: "Recording saved",
                detail: "Syncing to iPhone in the background. You can keep using MotionOS.",
                symbol: "arrow.up.doc.fill",
                showRetry: false,
                canDelete: true
            )

        case .transportComplete:
            completedCapturePanel(
                title: "Recording sent",
                detail: "The iPhone is verifying the recording now.",
                symbol: "iphone.and.arrow.forward",
                showRetry: true,
                canDelete: true
            )

        case .transferred:
            completedCapturePanel(
                title: "Saved on iPhone",
                detail: "Verification passed. The Watch copy has been cleaned up.",
                symbol: "checkmark.seal.fill",
                showRetry: false,
                canDelete: false
            )

        case .failed:
            EmptyView()

        case .running, .paused:
            EmptyView()
        }
    }

    private var captureDashboard: some View {
        VStack(spacing: 9) {
            if let status = controller.indoRemoteStatus,
               status.sessionPhase.lowercased() == "countdown" {
                countdownPanel(status.countdownRemaining ?? 1)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 2) {
                    Text(
                        controller.startedAt.map {
                            duration(from: $0, to: context.date)
                        } ?? "00:00"
                    )
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(captureLiveColor(at: context.date))
                            .frame(width: 6, height: 6)
                        Text(captureLiveLabel(at: context.date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(captureLiveColor(at: context.date))

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(controller.captureOrigin.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            }

            if let cue = controller.guidedCueTitle {
                protocolCueCard(cue)
            }

            if controller.indoRemoteProductSessionActive {
                Button {
                    _ = controller.sendIndoRemoteCommand(.finishSession)
                } label: {
                    Label(
                        controller.indoRemoteCommandPending
                            ? "Finishing…"
                            : "Finish Session",
                        systemImage: "stop.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(
                    controller.indoRemoteCommandPending
                        || !controller.phoneReachable
                )

                if !controller.phoneReachable {
                    Text(
                        "iPhone link lost. The timed protocol can still auto-finish. "
                            + "Use the local stop only if you need to end the Watch recording now."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        confirmStop = true
                    } label: {
                        Label(
                            "Stop Watch Recording",
                            systemImage: "stop.circle"
                        )
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 7) {
                    Button {
                        if controller.state == .running {
                            controller.pause()
                        } else {
                            controller.resume()
                        }
                    } label: {
                        Image(
                            systemName: controller.state == .running
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        controller.state == .running
                            ? "Pause capture"
                            : "Resume capture"
                    )

                    Button {
                        confirmStop = true
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Stop capture")
                }
            }

            WatchMotionTrace(
                points: controller.visualTelemetryHistory,
                currentUserAccelerationG: controller.userAccelerationG,
                currentRotationRate: controller.rotationRateRadS
            )

            HStack(spacing: 6) {
                metricTile(
                    title: "MOTION",
                    value: controller.userAccelerationG.map {
                        String(format: "%.2f", $0)
                    } ?? "—",
                    unit: "g"
                )

                metricTile(
                    title: "HEART",
                    value: controller.heartRateBPM.map {
                        "\(Int($0.rounded()))"
                    } ?? "—",
                    unit: "BPM"
                )
            }

            Label(streamText, systemImage: streamClean ? "checkmark.shield" : "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(streamClean ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let battery = controller.watchBatteryLevel, battery < 0.20 {
                Label(String(format: "Battery %.0f%%", battery * 100), systemImage: "battery.25percent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelStyle()
    }

    private func protocolCueCard(
        _ title: String
    ) -> some View {
        let isSync = title == "SYNC · MOVE NOW"
        let detail = isSync
            ? "Sharp arm gesture now. Keep the board near neutral."
            : controller.productCueInstruction

        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(
                    systemName: isSync
                        ? "bolt.fill"
                        : "figure.surfing"
                )
                Text(isSync ? "SYNC" : "SESSION")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isSync ? .cyan : .secondary)

            Text(title)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let detail,
               !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            (isSync ? Color.cyan : Color.primary)
                .opacity(isSync ? 0.12 : 0.055),
            in: RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }

    private var streamClean: Bool {
        controller.nonMonotonicIMUCount == 0 && controller.maxIMUGapMS <= 100
    }

    private var streamText: String {
        let rate = controller.recentMedianIMUHz.map { String(format: "%.1f Hz", $0) } ?? "IMU —"
        if controller.nonMonotonicIMUCount > 0 {
            return "\(rate) · time reversals"
        }
        if controller.maxIMUGapMS > 100 {
            return "\(rate) · " + String(format: "gap %.0f ms", controller.maxIMUGapMS)
        }
        return "\(rate) · stream clean"
    }

    /// Engineering detail stays one tap away and out of the primary flow.
    private var detailsSection: some View {
        VStack(spacing: 6) {
            Button {
                showDetails.toggle()
            } label: {
                Label(showDetails ? "Hide Details" : "Details", systemImage: "info.circle")
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)

            if showDetails {
                if controller.healthAccessReady
                    && controller.canStartCapture
                    && !controller.indoRemoteProductSessionActive {
                    Button {
                        Task { await controller.startLocalSensorCheck() }
                    } label: {
                        Label("Watch Sensor Check", systemImage: "waveform.path.ecg")
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                let rejections = controller.captureRejections
                VStack(alignment: .leading, spacing: 3) {
                    detailLine("IMU samples", "\(controller.imuSampleCount)")
                    detailLine("Max gap", String(format: "%.0f ms", controller.maxIMUGapMS))
                    detailLine("Phone link", controller.phoneReachable ? "live" : "background")
                    detailLine(
                        "Live preview",
                        "\(controller.liveTelemetryAttemptedCount) sent · "
                            + "\(controller.liveTelemetryDroppedCount) dropped"
                    )
                    detailLine(
                        "Not journaled",
                        "\(rejections.afterShutdown) late · "
                            + "\(rejections.sessionMismatch &+ rejections.noActiveSession) foreign · "
                            + "\(rejections.staleMotionGeneration) stale · "
                            + "\(controller.rejectedProductControlCount) control"
                    )
                    if let battery = controller.watchBatteryLevel {
                        detailLine("Battery", String(format: "%.0f%%", battery * 100))
                    }
                    detailLine("Build", buildString)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelStyle()
            }
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Capture issue", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.hasRecoverableJournal {
                Button {
                    controller.retryTransfer()
                } label: {
                    Label("Transfer Saved Journal", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func progressPanel(
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(statusColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .panelStyle()
    }

    private func completedCapturePanel(
        title: String,
        detail: String,
        symbol: String,
        showRetry: Bool,
        canDelete: Bool
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(
                    controller.state == .transferred
                        ? Color.green
                        : Color.cyan
                )

            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.dismissCompletedCapture()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if showRetry {
                Button {
                    controller.retryTransfer()
                } label: {
                    Label("Retry Sync", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if canDelete {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Recording", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .panelStyle()
    }

    private func readinessRow(
        title: String,
        value: String,
        symbol: String,
        ready: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(ready ? .green : .secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ready ? .green : .secondary)
                .lineLimit(1)
        }
    }

    private func metricTile(
        title: String,
        value: String,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
    }

    private var buildString: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        return "v\(version) · b\(build)"
    }

    private var isCaptureActive: Bool {
        controller.state == .running || controller.state == .paused
    }

    private var statusText: String {
        switch controller.state {
        case .idle:
            controller.healthAccessReady ? "READY" : "SETUP"
        case .authorizing:
            "HEALTH"
        case .starting:
            "STARTING"
        case .running:
            "RECORDING"
        case .paused:
            "PAUSED"
        case .ending:
            "FINISHING"
        case .journalReady, .transferQueued, .transportComplete:
            "SAVED"
        case .transferred:
            "SAVED"
        case .failed:
            "CHECK"
        }
    }

    private var statusSymbol: String {
        switch controller.state {
        case .running:
            "waveform.path.ecg"
        case .paused:
            "pause.fill"
        case .transferred:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .journalReady, .transferQueued, .transportComplete:
            "checkmark.doc.fill"
        default:
            "figure.run"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running, .transferred:
            .green
        case .paused, .starting, .ending, .authorizing,
                .journalReady, .transferQueued, .transportComplete:
            .yellow
        case .failed:
            .red
        default:
            .secondary
        }
    }

    private func captureLiveColor(at date: Date) -> Color {
        guard let last = controller.lastIMUSampleReceivedAt else {
            return .yellow
        }
        return date.timeIntervalSince(last) < 2 ? .green : .red
    }

    private func captureLiveLabel(at date: Date) -> String {
        guard let last = controller.lastIMUSampleReceivedAt else {
            return "WARMING UP"
        }
        let age = max(0, date.timeIntervalSince(last))
        return age < 2 ? "LIVE" : String(format: "STALE %.0fs", age)
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(10)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.085),
                        Color.white.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }
}
