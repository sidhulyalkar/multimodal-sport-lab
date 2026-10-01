import MotionOSAppleCapture
import SwiftUI
import UniformTypeIdentifiers

struct VisionLabCard: View {
    @EnvironmentObject private var coordinator: PhoneSessionCoordinator
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var vision: VisionLabController

    @State private var importingAction4 = false
    @State private var flashVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Indo Board · M0-Vision", systemImage: "figure.surfing")
                    .font(.headline)
                Spacer()
                Text(vision.phase.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            Text(
                "Watch IMU + iPhone vision + Action 4 evidence, kept on "
                    + "separate clocks until explicit synchronization."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let sessionID = vision.sessionID {
                Text(sessionID)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }

            Picker(
                "Feedback condition",
                selection: $vision.coachingCondition
            ) {
                Text("No live feedback")
                    .tag(CoachingCondition.feedbackDisabled)
                Text("Sparse Watch feedback")
                    .tag(CoachingCondition.feedbackEnabled)
            }
            .pickerStyle(.segmented)
            .disabled(vision.phase == .capturing)

            Toggle(
                "Action 4 · 4K/60 · EIS off · Standard (Dewarp) · recording",
                isOn: $vision.action4RecordingConfirmed
            )
            .disabled(vision.phase == .capturing)

            Text(
                "This confirmation is sealed into the vision session. "
                    + "Do not change Action 4 FOV, stabilization, resolution, "
                    + "or frame rate after camera calibration."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            if vision.phase == .idle
                || vision.phase == .sealed
                || vision.phase == .failed {
                Button {
                    Task { await armSession() }
                } label: {
                    Label("Arm New Indo Board Session", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if vision.phase == .armed {
                capturePreflight

                Button {
                    Task { await startCoordinatedCapture() }
                } label: {
                    Label(
                        "Start Watch + iPhone Capture",
                        systemImage: "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!captureReady)
            }

            if vision.phase == .capturing {
                Button {
                    emitSyncCue()
                } label: {
                    Label(
                        "SYNC · Chirp + Flash + Watch Haptic",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.watchReachable)

                syncProgress

                Text(
                    "When cued, make one sharp whole-body/board impulse. "
                        + "Repeat near the beginning, middle, and end."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !vision.hasMinimumSyncLandmarks {
                    Label(
                        "Collect at least "
                            + "\(VisionLabController.minimumSyncLandmarkCount) "
                            + "Watch-acknowledged SYNC landmarks before sealing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.yellow)
                }

                Button {
                    Task { await finishCapture() }
                } label: {
                    Label(
                        "Stop iPhone & Seal Vision Sidecar",
                        systemImage: "stop.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if vision.phase == .sealed {
                if let bundle = camera.evidenceBundle {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("iPhone sealed evidence")
                            .font(.subheadline.weight(.semibold))

                        ShareLink(item: bundle.videoURL) {
                            Label(
                                "Share iPhone camera.mov",
                                systemImage: "video"
                            )
                        }
                        ShareLink(item: bundle.journalURL) {
                            Label(
                                "Share iPhone camera-frames.jsonl",
                                systemImage: "doc.text"
                            )
                        }
                        ShareLink(item: bundle.metadataURL) {
                            Label(
                                "Share iPhone camera-metadata.json",
                                systemImage: "checkmark.seal"
                            )
                        }
                    }
                    .font(.caption)
                }

                Button {
                    importingAction4 = true
                } label: {
                    Label(
                        vision.mediaArtifacts.isEmpty
                            ? "Import Original Action 4 Movie"
                            : "Replace Action 4 Movie",
                        systemImage: "video.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let artifact = vision.mediaArtifacts.first(
                    where: { $0.sourceID == "dji-action4" }
                ) {
                    Label(
                        "Action 4 verified · \(artifact.sha256.prefix(12))…",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)

                    if vision.action4PosePhase == .idle
                        || vision.action4PosePhase == .failed {
                        Button {
                            Task {
                                await vision.processAction4Pose2D()
                            }
                        } label: {
                            Label(
                                "Extract Action 4 2D Pose",
                                systemImage: "figure.walk.motion"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if vision.action4PosePhase == .processing {
                        HStack {
                            ProgressView()
                            Text("Extracting timestamped 2D pose…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if vision.action4PosePhase == .ready {
                        Label(
                            "\(vision.action4PoseCount) poses from "
                                + "\(vision.action4PoseFrameCount) frames",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)

                        if let movieURL = vision.mediaArtifactURL(
                            sourceID: "dji-action4"
                        ) {
                            ShareLink(item: movieURL) {
                                Label(
                                    "Share sealed Action 4 movie",
                                    systemImage: "video"
                                )
                            }
                        }
                        if let journalURL = vision.derivedArtifactURL(
                            sourceID: "dji-action4",
                            kind: "pose2d_journal"
                        ) {
                            ShareLink(item: journalURL) {
                                Label(
                                    "Share Action 4 pose journal",
                                    systemImage: "doc.text"
                                )
                            }
                        }
                        if let metadataURL = vision.derivedArtifactURL(
                            sourceID: "dji-action4",
                            kind: "pose2d_metadata"
                        ) {
                            ShareLink(item: metadataURL) {
                                Label(
                                    "Share Action 4 pose metadata",
                                    systemImage: "checkmark.seal"
                                )
                            }
                        }
                    }
                }

                if let manifestURL = vision.manifestURL {
                    ShareLink(item: manifestURL) {
                        Label(
                            "Share Vision Session Sidecar",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                sourcePill(
                    "Watch",
                    ready: coordinator.watchPaired
                        && coordinator.watchAppInstalled
                )
                sourcePill(
                    "iPhone",
                    ready: camera.phase == .ready
                        || camera.phase == .recording
                        || camera.phase == .evidenceReady
                )
                sourcePill(
                    "Action 4",
                    ready: vision.action4RecordingConfirmed
                        || !vision.mediaArtifacts.isEmpty
                )
            }

            if vision.coachingCondition == .feedbackEnabled {
                Text(
                    "Live coaching is confidence-gated. The Watch receives at "
                        + "most one short cue from the future fused-metric loop; "
                        + "no synthetic/demo metric is injected here."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let error = vision.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
        .overlay {
            if flashVisible {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .fileImporter(
            isPresented: $importingAction4,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            do {
                let url = try result.get().first
                guard let url else { return }
                try vision.importAction4Video(url)
                _ = try vision.sealSession()
            } catch {
                vision.fail(error)
            }
        }
        .onChange(
            of: coordinator.lastVisionSyncCueAcknowledgment
        ) { _, acknowledgment in
            guard let acknowledgment else { return }
            vision.acknowledgeSyncLandmark(
                landmarkID: acknowledgment.landmarkID,
                visionSessionID: acknowledgment.visionSessionID
            )
        }
    }

    private func armSession() async {
        _ = vision.armSession()
        coordinator.refreshWatchState()
        coordinator.refreshHostReadiness()

        if camera.phase == .idle
            || camera.phase == .failed
            || camera.phase == .denied {
            await camera.prepare()
        }
        if let configuration = camera.configuration {
            vision.bindIPhoneCamera(configuration)
        }
    }

    private var captureReady: Bool {
        coordinator.watchPaired
            && coordinator.watchAppInstalled
            && coordinator.watchReachable
            && vision.action4RecordingConfirmed
            && (
                camera.phase == .ready
                    || camera.phase == .evidenceReady
            )
            && (coordinator.iPhoneBatteryLevel ?? 0) >= 0.20
            && (coordinator.iPhoneAvailableStorageBytes ?? 0)
                >= 5_000_000_000
    }

    private var capturePreflight: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Capture preflight")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        coordinator.refreshWatchState()
                        coordinator.refreshHostReadiness()
                        if camera.phase == .idle
                            || camera.phase == .failed
                            || camera.phase == .denied {
                            await camera.prepare()
                        }
                        if let configuration = camera.configuration {
                            vision.bindIPhoneCamera(configuration)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh capture preflight")
            }

            readinessRow(
                "Watch paired",
                ready: coordinator.watchPaired,
                value: coordinator.watchPaired ? "yes" : "no"
            )
            readinessRow(
                "Watch app",
                ready: coordinator.watchAppInstalled,
                value: coordinator.watchAppInstalled
                    ? "installed"
                    : "missing"
            )
            readinessRow(
                "Watch reachable",
                ready: coordinator.watchReachable,
                value: coordinator.watchReachable
                    ? "reachable"
                    : "not reachable"
            )
            readinessRow(
                "iPhone camera",
                ready: camera.phase == .ready
                    || camera.phase == .evidenceReady,
                value: camera.phase.rawValue
            )
            readinessRow(
                "iPhone battery",
                ready: (coordinator.iPhoneBatteryLevel ?? 0) >= 0.20,
                value: coordinator.iPhoneBatteryLevel.map {
                    String(format: "%.0f%%", $0 * 100)
                } ?? "unknown"
            )
            readinessRow(
                "Free storage",
                ready: (coordinator.iPhoneAvailableStorageBytes ?? 0)
                    >= 5_000_000_000,
                value: coordinator.iPhoneAvailableStorageBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: $0,
                        countStyle: .file
                    )
                } ?? "unknown"
            )
            readinessRow(
                "Action 4 profile",
                ready: vision.action4RecordingConfirmed,
                value: vision.action4RecordingConfirmed
                    ? "4K60 · EIS off · Dewarp"
                    : "not confirmed"
            )
        }
    }

    private var syncProgress: some View {
        let count = vision.acknowledgedSyncLandmarkCount
        let pending = vision.pendingSyncLandmarkCount
        let required = VisionLabController.minimumSyncLandmarkCount
        let ready = count >= required

        return HStack {
            Image(
                systemName: ready
                    ? "checkmark.circle.fill"
                    : "circle.dashed"
            )
            .foregroundStyle(ready ? .green : .yellow)

            Text("Watch-journaled SYNC")
                .font(.caption)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(count)/\(required) acknowledged")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ready ? .green : .secondary)
                if pending > 0 {
                    Text("\(pending) awaiting Watch receipt")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    private func readinessRow(
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

    private func startCoordinatedCapture() async {
        guard let id = vision.sessionID else {
            vision.fail(VisionLabController.VisionLabError.sessionNotArmed)
            return
        }
        guard vision.action4RecordingConfirmed else {
            vision.fail(VisionLabController.VisionLabError.action4NotConfirmed)
            return
        }

        if coordinator.state != .running
            && coordinator.state != .paused
            && coordinator.state != .waitingForMirror
            && coordinator.state != .launchingWatch {
            await coordinator.startP0()
        }
        guard coordinator.state != .failed else { return }

        if camera.phase == .idle
            || camera.phase == .failed
            || camera.phase == .denied {
            await camera.prepare()
        }
        guard camera.phase == .ready || camera.phase == .evidenceReady else {
            return
        }

        await camera.startRecording(sessionID: id)
        guard camera.phase == .recording else { return }
        if let configuration = camera.configuration {
            vision.bindIPhoneCamera(configuration)
        }
        vision.markCapturing()
    }

    private func emitSyncCue() {
        guard coordinator.watchReachable else { return }
        guard let landmark = vision.emitSyncLandmark() else { return }

        guard coordinator.sendVisionSyncCue(landmark) else {
            vision.discardUnacknowledgedSyncLandmark(
                landmarkID: landmark.landmarkID,
                message: (
                    "Watch became unreachable before the SYNC cue "
                        + "could be sent. Retry SYNC."
                )
            )
            return
        }

        vision.emitLocalSyncSignals()
        withAnimation(.easeIn(duration: 0.03)) {
            flashVisible = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.08)) {
                flashVisible = false
            }

            try? await Task.sleep(for: .milliseconds(4_880))
            vision.discardUnacknowledgedSyncLandmark(
                landmarkID: landmark.landmarkID,
                message: (
                    "Watch did not acknowledge journaling the SYNC cue "
                        + "within 5 seconds. Retry SYNC."
                )
            )
        }
    }

    private func finishCapture() async {
        if camera.phase == .recording {
            await camera.stopRecording()
        }
        do {
            _ = try vision.sealSession()
        } catch {
            vision.fail(error)
        }
    }

    private func sourcePill(_ title: String, ready: Bool) -> some View {
        Label(
            title,
            systemImage: ready ? "checkmark.circle.fill" : "circle.dashed"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(ready ? .green : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }

    private var phaseColor: Color {
        switch vision.phase {
        case .capturing: .red
        case .armed: .yellow
        case .sealed: .green
        case .failed: .red
        default: .secondary
        }
    }
}
