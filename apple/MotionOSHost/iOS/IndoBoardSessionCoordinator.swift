import Combine
import Foundation
import MotionOSAppleCapture
import UIKit

@MainActor
final class IndoBoardSessionCoordinator: ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
        case watchAndPhone = "Watch + iPhone"
        case multiviewCalibration = "Multiview capture"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .watchAndPhone:
                "Fast product session with Watch + iPhone video."
            case .multiviewCalibration:
                "Camera-rich teacher session with Action 4 preserved for offline synchronization."
            }
        }

        var requiresExternalCamera: Bool {
            self == .multiviewCalibration
        }
    }

    enum Phase: String {
        case idle
        case preparing
        case ready
        case starting
        case running
        case finishing
        case watchStopRequired
        case sealed
        case failed
    }

    enum SessionError: LocalizedError {
        case watchUnavailable
        case cameraUnavailable
        case cameraProfileInvalid
        case insufficientBattery
        case insufficientStorage
        case watchDidNotStart
        case watchDidNotStop
        case syncUnavailable
        case fieldRunUnavailable

        var errorDescription: String? {
            switch self {
            case .watchUnavailable:
                "The paired MotionOS Watch must be installed and reachable."
            case .cameraUnavailable:
                "Prepare the iPhone camera before starting the Indo Board session."
            case .cameraProfileInvalid:
                "The iPhone camera must be 1920×1080 at a locked 30 fps with video stabilization off."
            case .insufficientBattery:
                "Charge the iPhone above the 20% development preflight margin."
            case .insufficientStorage:
                "Free at least 5 GB on the iPhone before recording."
            case .watchDidNotStart:
                "The Watch workout did not reach running state in time."
            case .watchDidNotStop:
                "The phone could not confirm Watch shutdown. Stop the capture on the Watch, then recheck before starting another session."
            case .syncUnavailable:
                "The Watch link is unavailable for a journal-backed sync cue."
            case .fieldRunUnavailable:
                "The operator run could not be armed."
            }
        }
    }

    struct ExternalVideoEvidence: Equatable, Sendable {
        let videoURL: URL
        let metadataURL: URL
        let originalFilename: String
        let sha256: String
        let byteCount: UInt64
    }

    struct CueReceipt: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let acknowledgedAt: Date
        let watchDeviceTimeNS: UInt64
    }

    static let targetDurationSeconds: TimeInterval = 120

    @Published private(set) var phase: Phase = .idle
    @Published var captureMode: CaptureMode = .watchAndPhone
    @Published private(set) var startedAt: Date?
    @Published private(set) var cueReceipts: [CueReceipt] = []
    @Published private(set) var pendingCueID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var externalVideoEvidence:
        ExternalVideoEvidence?
    @Published private(set) var productManifestURL: URL?
    @Published var externalCameraConfirmed = false

    private var protocolTask: Task<Void, Never>?
    private var syncTimeoutTask: Task<Void, Never>?
    private var protocolTransitions: Set<String> = []
    private var lastCueAttemptAt: [String: Date] = [:]

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    var progress: Double {
        min(1, elapsedSeconds / Self.targetDurationSeconds)
    }

    var acknowledgedCueLabels: Set<String> {
        Set(cueReceipts.map(\.label))
    }

    var currentInstruction: String {
        instruction(at: elapsedSeconds)
    }

    var requiresExternalCamera: Bool {
        captureMode.requiresExternalCamera
    }

    var syncProgress: Double {
        min(1, Double(cueReceipts.count) / 3.0)
    }

    func prepare(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController
    ) async {
        phase = .preparing
        errorMessage = nil

        phone.refreshWatchState()
        phone.refreshHostReadiness()

        if camera.phase == .idle
            || camera.phase == .failed
            || camera.phase == .denied {
            await camera.prepare()
        }

        guard phone.watchPaired && phone.watchAppInstalled
        else {
            fail(SessionError.watchUnavailable)
            return
        }
        guard camera.phase == .ready
                || camera.phase == .evidenceReady
        else {
            fail(SessionError.cameraUnavailable)
            return
        }
        guard cameraProfileReady(camera) else {
            fail(SessionError.cameraProfileInvalid)
            return
        }
        guard (phone.iPhoneBatteryLevel ?? 0) >= 0.20 else {
            fail(SessionError.insufficientBattery)
            return
        }
        guard (phone.iPhoneAvailableStorageBytes ?? 0)
                >= 5_000_000_000
        else {
            fail(SessionError.insufficientStorage)
            return
        }

        if requiresExternalCamera && !externalCameraConfirmed {
            errorMessage = (
                "Multiview calibration requires the Action 4 to be started "
                    + "and its fixed capture profile confirmed before recording."
            )
            phase = .idle
            return
        }

        phase = .ready
    }

    func start(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        fieldRun: FieldRunCoordinator,
        pod: EquipmentPodController
    ) async {
        if phase != .ready {
            await prepare(phone: phone, camera: camera)
        }
        guard phase == .ready else { return }

        phase = .starting
        errorMessage = nil
        cueReceipts = []
        pendingCueID = nil
        externalVideoEvidence = nil
        productManifestURL = nil
        startedAt = nil

        fieldRun.createRun(kind: .indoBoard)
        guard fieldRun.phase == .armed,
              let runID = fieldRun.runID
        else {
            fail(SessionError.fieldRunUnavailable)
            return
        }

        if phone.state != .running && phone.state != .paused {
            await phone.startP0()
        }

        guard await waitForWatchRunning(phone: phone)
        else {
            fail(SessionError.watchDidNotStart)
            return
        }

        if camera.phase != .ready && camera.phase != .evidenceReady {
            await camera.prepare()
        }
        guard camera.phase == .ready || camera.phase == .evidenceReady
        else {
            fail(SessionError.cameraUnavailable)
            return
        }
        guard cameraProfileReady(camera) else {
            fail(SessionError.cameraProfileInvalid)
            return
        }

        await camera.startRecording()
        guard camera.phase == .recording else {
            fail(SessionError.cameraUnavailable)
            return
        }

        let readiness = readinessSnapshot(
            phone: phone,
            camera: camera,
            pod: pod,
            runID: runID
        )
        fieldRun.startRun(readiness: readiness)
        guard fieldRun.phase == .running else {
            if camera.phase == .recording {
                await camera.stopRecording()
            }
            fail(SessionError.fieldRunUnavailable)
            return
        }

        startedAt = Date()
        phase = .running
        UIApplication.shared.isIdleTimerDisabled = true
        startProtocolTimeline(
            phone: phone,
            fieldRun: fieldRun
        )
    }

    @discardableResult
    func emitSyncCue(
        label: String,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) -> String? {
        guard phase == .running,
              let runID = fieldRun.runID
        else {
            return nil
        }

        guard phone.watchReachable else {
            errorMessage = (
                "The Watch live link is temporarily unavailable. "
                    + "Raw Watch capture can continue; MotionOS will retry "
                    + "the sync cue while its window remains open."
            )
            return nil
        }

        let normalized = label.lowercased()
        guard !acknowledgedCueLabels.contains(normalized),
              pendingCueID == nil
        else {
            return nil
        }

        let cueID = "sync-\(normalized)-\(UUID().uuidString.prefix(6).lowercased())"
        guard phone.sendSessionSyncCue(
            runID: runID,
            cueID: cueID,
            label: normalized
        )
        else {
            errorMessage = (
                "The "
                    + normalized.uppercased()
                    + " sync cue could not be sent yet. "
                    + "Raw capture is still running and MotionOS will retry."
            )
            return nil
        }

        pendingCueID = cueID
        errorMessage = nil

        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                  self.pendingCueID == cueID
            else {
                return
            }
            self.pendingCueID = nil
            self.errorMessage = (
                "The Watch did not acknowledge the "
                    + normalized.uppercased()
                    + " sync cue. MotionOS can retry while the cue window is open."
            )
        }
        return cueID
    }

    func acknowledge(
        _ acknowledgment: SessionSyncAcknowledgment,
        fieldRun: FieldRunCoordinator
    ) {
        guard phase == .running,
              acknowledgment.runID == fieldRun.runID,
              acknowledgment.cueID == pendingCueID
        else {
            return
        }

        let normalized = acknowledgment.label.lowercased()
        if !acknowledgedCueLabels.contains(normalized) {
            cueReceipts.append(
                CueReceipt(
                    id: acknowledgment.cueID,
                    label: normalized,
                    acknowledgedAt: acknowledgment.receivedAt,
                    watchDeviceTimeNS: acknowledgment.watchDeviceTimeNS
                )
            )
            fieldRun.markSyncCue(normalized)
        }

        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        pendingCueID = nil
        errorMessage = nil
    }

    func finish(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        fieldRun: FieldRunCoordinator,
        pod: EquipmentPodController
    ) async {
        guard phase == .running else { return }
        phase = .finishing
        errorMessage = nil

        let stopRequested: Bool
        if let runID = fieldRun.runID {
            stopRequested = phone.sendWatchStopRequest(
                runID: runID
            )
        } else {
            stopRequested = false
        }

        let watchStopped = stopRequested
            ? await waitForWatchToLeaveRunning(phone: phone)
            : false

        if camera.phase == .recording {
            await camera.stopRecording()
        }

        if fieldRun.phase == .running || fieldRun.phase == .armed {
            fieldRun.seal(
                readiness: readinessSnapshot(
                    phone: phone,
                    camera: camera,
                    pod: pod,
                    runID: fieldRun.runID ?? "unknown"
                )
            )
        }

        protocolTask?.cancel()
        protocolTask = nil
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        UIApplication.shared.isIdleTimerDisabled = false

        if fieldRun.phase == .sealed {
            do {
                productManifestURL = try writeProductManifest(
                    phone: phone,
                    camera: camera,
                    fieldRun: fieldRun
                )

                if watchStopped
                    || (
                        phone.state != .running
                            && phone.state != .paused
                            && phone.state != .waitingForMirror
                            && phone.state != .launchingWatch
                    ) {
                    phase = .sealed
                } else {
                    phase = .watchStopRequired
                    errorMessage =
                        SessionError.watchDidNotStop.localizedDescription
                }
            } catch {
                fail(error)
            }
        } else {
            fail(SessionError.fieldRunUnavailable)
        }
    }

    func importExternalVideo(
        from sourceURL: URL,
        runDirectory: URL,
        runID: String
    ) async {
        errorMessage = nil

        let gainedAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if gainedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let evidence = try await Task.detached(
                priority: .utility
            ) {
                let manager = FileManager.default
                let directory = runDirectory
                    .appendingPathComponent(
                        "external",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        "action4",
                        isDirectory: true
                    )
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                let safeName = sourceURL.lastPathComponent.isEmpty
                    ? "action4.mov"
                    : sourceURL.lastPathComponent
                let destination = directory.appendingPathComponent(
                    "original-" + safeName
                )

                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(
                    at: sourceURL,
                    to: destination
                )

                let digest = try FileEvidence.digest(destination)
                let metadataURL = directory.appendingPathComponent(
                    "external-camera-metadata.json"
                )
                let metadata: [String: Any] = [
                    "schema_version":
                        "motionos.external-video-evidence.v1",
                    "run_id": runID,
                    "source": "dji_action4",
                    "original_filename": safeName,
                    "sha256": digest.sha256,
                    "byte_count": digest.byteCount,
                    "imported_at_utc":
                        ISO8601DateFormatter().string(from: Date()),
                    "acquisition_profile_confirmation":
                        "operator_confirmed_when_enabled",
                    "claim_boundary":
                        "The imported file is preserved and hash-bound. "
                            + "Camera settings remain operator-confirmed "
                            + "unless independently verified downstream.",
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: metadata,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(
                    to: metadataURL,
                    options: .atomic
                )

                return ExternalVideoEvidence(
                    videoURL: destination,
                    metadataURL: metadataURL,
                    originalFilename: safeName,
                    sha256: digest.sha256,
                    byteCount: digest.byteCount
                )
            }
            .value

            externalVideoEvidence = evidence

            let manifestURL = runDirectory.appendingPathComponent(
                "product-session.json"
            )
            if FileManager.default.fileExists(atPath: manifestURL.path),
               let existing = try? ProductSessionManifestStore.load(
                    from: manifestURL
               ) {
                let updated = ProductSessionManifest(
                    runID: existing.runID,
                    captureMode: existing.captureMode,
                    targetDurationSeconds: existing.targetDurationSeconds,
                    watchSessionID: existing.watchSessionID,
                    cameraSessionID: existing.cameraSessionID,
                    syncReceipts: existing.syncReceipts,
                    externalCameraExpected: existing.externalCameraExpected,
                    externalCameraImported: true,
                    externalCameraSHA256: evidence.sha256,
                    operatorEvidenceSealed: existing.operatorEvidenceSealed,
                    cameraEvidenceSealed: existing.cameraEvidenceSealed
                )
                productManifestURL = try ProductSessionManifestStore.write(
                    updated,
                    to: runDirectory
                )
            }
        } catch {
            errorMessage = (
                "External video import failed: "
                    + error.localizedDescription
            )
        }
    }

    func recheckWatchStop(
        phone: PhoneSessionCoordinator
    ) {
        guard phase == .watchStopRequired else {
            return
        }

        phone.refreshWatchState()
        if phone.state != .running
            && phone.state != .paused
            && phone.state != .waitingForMirror
            && phone.state != .launchingWatch {
            phase = .sealed
            errorMessage = nil
        } else {
            errorMessage =
                SessionError.watchDidNotStop.localizedDescription
        }
    }

    func reset() {
        guard phase != .running
                && phase != .starting
                && phase != .finishing
                && phase != .watchStopRequired
        else {
            return
        }
        protocolTask?.cancel()
        protocolTask = nil
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        protocolTransitions = []
        lastCueAttemptAt = [:]
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
        startedAt = nil
        cueReceipts = []
        pendingCueID = nil
        externalVideoEvidence = nil
        productManifestURL = nil
        errorMessage = nil
    }

    func instruction(
        at elapsed: TimeInterval
    ) -> String {
        switch elapsed {
        case ..<10:
            "Settle into neutral balance."
        case ..<20:
            acknowledgedCueLabels.contains("start")
                ? "Return to neutral after the start sync gesture."
                : "When the Watch taps for START sync, make one sharp arm gesture."
        case ..<45:
            "Natural free balance. Stay comfortable and visible to camera."
        case ..<55:
            acknowledgedCueLabels.contains("middle")
                ? "Return to neutral after the middle sync gesture."
                : "When the Watch taps for MIDDLE sync, make one sharp arm gesture."
        case ..<90:
            "Five controlled tilt-and-recover cycles. Alternate directions."
        case ..<110:
            "Natural free balance, then settle toward neutral."
        case ..<120:
            acknowledgedCueLabels.contains("end")
                ? "Hold a comfortable neutral finish."
                : "When the Watch taps for END sync, make one sharp arm gesture."
        default:
            "Session target reached. Finish and seal when stable."
        }
    }

    private func startProtocolTimeline(
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) {
        protocolTask?.cancel()
        protocolTransitions = []
        fieldRun.startBlock("neutral-settle")

        protocolTask = Task { @MainActor [weak self, weak fieldRun] in
            while !Task.isCancelled {
                guard let self,
                      let fieldRun,
                      self.phase == .running
                else {
                    return
                }

                self.advanceProtocol(
                    elapsed: self.elapsedSeconds,
                    phone: phone,
                    fieldRun: fieldRun
                )
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func advanceProtocol(
        elapsed: TimeInterval,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) {
        transition(
            "complete-neutral-settle",
            when: elapsed >= 10
        ) {
            fieldRun.completeBlock("neutral-settle")
        }

        autoCue(
            "start",
            elapsed: elapsed,
            target: 12,
            windowEnd: 20,
            phone: phone,
            fieldRun: fieldRun
        )

        transition(
            "start-free-a",
            when: elapsed >= 20
        ) {
            fieldRun.startBlock("free-balance-a")
        }

        transition(
            "complete-free-a",
            when: elapsed >= 45
        ) {
            fieldRun.completeBlock("free-balance-a")
        }

        autoCue(
            "middle",
            elapsed: elapsed,
            target: 50,
            windowEnd: 58,
            phone: phone,
            fieldRun: fieldRun
        )

        transition(
            "start-tilt-recover",
            when: elapsed >= 55
        ) {
            fieldRun.startBlock("tilt-recover")
        }

        transition(
            "complete-tilt-recover",
            when: elapsed >= 90
        ) {
            fieldRun.completeBlock("tilt-recover")
        }

        transition(
            "start-free-b",
            when: elapsed >= 95
        ) {
            fieldRun.startBlock("free-balance-b")
        }

        transition(
            "complete-free-b",
            when: elapsed >= 110
        ) {
            fieldRun.completeBlock("free-balance-b")
        }

        transition(
            "start-neutral-finish",
            when: elapsed >= 110
        ) {
            fieldRun.startBlock("neutral-finish")
        }

        autoCue(
            "end",
            elapsed: elapsed,
            target: 110,
            windowEnd: 120,
            phone: phone,
            fieldRun: fieldRun
        )

        transition(
            "complete-neutral-finish",
            when: elapsed >= 120
        ) {
            fieldRun.completeBlock("neutral-finish")
        }
    }

    private func autoCue(
        _ label: String,
        elapsed: TimeInterval,
        target: TimeInterval,
        windowEnd: TimeInterval,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) {
        guard elapsed >= target,
              elapsed <= windowEnd,
              !acknowledgedCueLabels.contains(label),
              pendingCueID == nil
        else {
            return
        }

        let now = Date()
        if let previous = lastCueAttemptAt[label],
           now.timeIntervalSince(previous) < 3 {
            return
        }
        lastCueAttemptAt[label] = now

        _ = emitSyncCue(
            label: label,
            phone: phone,
            fieldRun: fieldRun
        )
    }

    private func transition(
        _ id: String,
        when condition: Bool,
        action: () -> Void
    ) {
        guard condition,
              !protocolTransitions.contains(id)
        else {
            return
        }
        protocolTransitions.insert(id)
        action()
    }

    func cameraProfileReady(
        _ camera: CameraCaptureController
    ) -> Bool {
        guard let configuration = camera.configuration else {
            return false
        }

        return configuration.formatWidth == 1_920
            && configuration.formatHeight == 1_080
            && configuration.frameRateLocked
            && abs(configuration.configuredFrameRate - 30.0) < 0.01
            && configuration.stabilizationLockedOff
    }

    private func waitForWatchRunning(
        phone: PhoneSessionCoordinator,
        timeoutSeconds: TimeInterval = 20
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if phone.state == .running || phone.state == .paused {
                return true
            }
            if phone.state == .failed {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return phone.state == .running || phone.state == .paused
    }

    private func waitForWatchToLeaveRunning(
        phone: PhoneSessionCoordinator,
        timeoutSeconds: TimeInterval = 12
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if phone.state != .running
                && phone.state != .paused
                && phone.state != .waitingForMirror
                && phone.state != .launchingWatch {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func readinessSnapshot(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        pod: EquipmentPodController,
        runID: String
    ) -> [String: String] {
        [
            "run_id": runID,
            "sport": "indo_board",
            "watch_paired": String(phone.watchPaired),
            "watch_app_installed": String(phone.watchAppInstalled),
            "watch_reachable": String(phone.watchReachable),
            "watch_workout_state": phone.state.rawValue,
            "watch_session_id":
                phone.watchCaptureHealth?.sessionID ?? "unknown",
            "iphone_camera_phase": camera.phase.rawValue,
            "iphone_camera_session_id":
                camera.sessionID ?? "unknown",
            "equipment_pod_phase": pod.phase.rawValue,
            "capture_mode": captureMode.rawValue,
            "external_camera_confirmed":
                String(externalCameraConfirmed),
            "sync_acknowledged":
                cueReceipts.map(\.label).sorted().joined(separator: ","),
        ]
    }

    private func writeProductManifest(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        fieldRun: FieldRunCoordinator
    ) throws -> URL {
        guard let runID = fieldRun.runID,
              let bundle = fieldRun.evidenceBundle
        else {
            throw SessionError.fieldRunUnavailable
        }

        let receipts = cueReceipts.map {
            ProductSessionManifest.SyncReceipt(
                cueID: $0.id,
                label: $0.label,
                acknowledgedAtUTC:
                    ISO8601DateFormatter().string(
                        from: $0.acknowledgedAt
                    ),
                watchDeviceTimeNS: $0.watchDeviceTimeNS
            )
        }

        let manifest = ProductSessionManifest(
            runID: runID,
            captureMode: captureMode.rawValue,
            targetDurationSeconds: Self.targetDurationSeconds,
            watchSessionID: phone.watchCaptureHealth?.sessionID,
            cameraSessionID: camera.sessionID,
            syncReceipts: receipts,
            externalCameraExpected: requiresExternalCamera,
            externalCameraImported: externalVideoEvidence != nil,
            externalCameraSHA256: externalVideoEvidence?.sha256,
            operatorEvidenceSealed: fieldRun.phase == .sealed,
            cameraEvidenceSealed: camera.phase == .evidenceReady
        )

        return try ProductSessionManifestStore.write(
            manifest,
            to: bundle.directory
        )
    }

    private func fail(_ error: Error) {
        protocolTask?.cancel()
        protocolTask = nil
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .failed
        errorMessage = error.localizedDescription
    }
}
