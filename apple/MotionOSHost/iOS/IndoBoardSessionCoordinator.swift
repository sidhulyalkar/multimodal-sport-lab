import Combine
import Foundation
import MotionOSAppleCapture
import UIKit

private enum ExternalVideoImportError: LocalizedError {
    case conflictingExistingEvidence(String)

    var errorDescription: String? {
        switch self {
        case .conflictingExistingEvidence(let filename):
            "This run already contains a different external movie named "
                + filename
                + ". MotionOS will not overwrite sealed evidence."
        }
    }
}

@MainActor
final class IndoBoardSessionCoordinator: ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
        case watchAndPhone = "Watch + iPhone"
        case multiviewCalibration = "Multiview capture"

        var id: String { rawValue }

        /// User-facing name. `rawValue` is persisted in session evidence and
        /// must not change.
        var displayName: String {
            switch self {
            case .watchAndPhone:
                "Watch + iPhone"
            case .multiviewCalibration:
                "With external camera"
            }
        }

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
        case countdown
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
        case watchCaptureAlreadyActive
        case watchWorkoutAccessUnavailable
        case watchDidNotStart
        case watchIdentityUnavailable
        case watchDidNotStop
        case syncUnavailable
        case fieldRunUnavailable

        var errorDescription: String? {
            switch self {
            case .watchUnavailable:
                "MotionOS must be installed on the active paired Apple Watch."
            case .cameraUnavailable:
                "Prepare the iPhone camera before starting the Indo Board session."
            case .cameraProfileInvalid:
                "The iPhone camera must be 1920×1080 at a locked 30 fps with video stabilization off."
            case .insufficientBattery:
                "Charge the iPhone above the 20% development preflight margin."
            case .insufficientStorage:
                "Free at least 5 GB on the iPhone before recording."
            case .watchCaptureAlreadyActive:
                "Finish the current Watch capture before starting an Indo Board product session."
            case .watchWorkoutAccessUnavailable:
                "Enable workout access in MotionOS on the Apple Watch before starting this session."
            case .watchDidNotStart:
                "The Watch workout did not reach running state in time."
            case .watchIdentityUnavailable:
                "The Watch started, but MotionOS did not receive a fresh capture identity. Stop the Watch capture before retrying."
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

    static let targetDurationSeconds: TimeInterval =
        IndoBoardProductProtocol.targetDurationSeconds

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var outcome: ProductSessionOutcome?
    @Published private(set) var activeWatchSessionID: String?
    @Published var captureMode: CaptureMode = .watchAndPhone
    @Published private(set) var startedAt: Date?
    @Published private(set) var countdownRemaining: Int?
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
    private var sentProtocolCueIDs: Set<String> = []
    private var lastProtocolCueAttemptAt: [String: Date] = [:]
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
            || camera.phase == .denied
            || camera.phase == .evidenceReady {
            // A sealed camera run stops AVCaptureSession. Restart preview
            // before treating the next product session as frame-ready.
            await camera.prepare()
        }

        guard phone.watchPaired && phone.watchAppInstalled
        else {
            fail(SessionError.watchUnavailable)
            return
        }
        guard watchCaptureAvailable(phone) else {
            fail(SessionError.watchCaptureAlreadyActive)
            return
        }
        guard watchWorkoutAccessReady(phone) else {
            fail(SessionError.watchWorkoutAccessUnavailable)
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
                "The external camera must be started "
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
        sentProtocolCueIDs = []
        lastProtocolCueAttemptAt = [:]
        externalVideoEvidence = nil
        productManifestURL = nil
        outcome = nil
        activeWatchSessionID = nil
        startedAt = nil
        countdownRemaining = nil

        fieldRun.createRun(kind: .indoBoard)
        guard fieldRun.phase == .armed,
              let runID = fieldRun.runID
        else {
            fail(SessionError.fieldRunUnavailable)
            return
        }

        let previousWatchSessionID =
            phone.watchPresence?.sessionID
                ?? phone.liveTelemetry.sessionID
        let watchLaunchRequestedAt = Date()

        await phone.startP0(locationType: .indoor)

        guard await waitForWatchRunning(phone: phone)
        else {
            await abortStart(
                error: .watchDidNotStart,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
            return
        }

        guard let watchSessionID =
            await waitForFreshWatchSessionID(
                phone: phone,
                after: watchLaunchRequestedAt,
                excluding: previousWatchSessionID
            )
        else {
            await abortStart(
                error: .watchIdentityUnavailable,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
            return
        }
        activeWatchSessionID = watchSessionID

        if camera.phase != .ready && camera.phase != .evidenceReady {
            await camera.prepare()
        }
        guard camera.phase == .ready || camera.phase == .evidenceReady
        else {
            await abortStart(
                error: .cameraUnavailable,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
            return
        }
        guard cameraProfileReady(camera) else {
            await abortStart(
                error: .cameraProfileInvalid,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
            return
        }

        await camera.startRecording()
        guard camera.phase == .recording else {
            await abortStart(
                error: .cameraUnavailable,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
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
            await abortStart(
                error: .fieldRunUnavailable,
                phone: phone,
                camera: camera,
                fieldRun: fieldRun,
                pod: pod
            )
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        phase = .countdown

        for value in stride(from: 5, through: 1, by: -1) {
            guard phase == .countdown else {
                return
            }
            countdownRemaining = value
            try? await Task.sleep(for: .seconds(1))
        }

        guard phase == .countdown else {
            return
        }
        countdownRemaining = nil
        camera.beginIndoCoachingSession()
        startedAt = Date()
        phase = .running
        startProtocolTimeline(
            phone: phone,
            camera: camera,
            fieldRun: fieldRun,
            pod: pod
        )
    }

    @discardableResult
    func emitSyncCue(
        label: String,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) -> String? {
        guard phase == .running,
              let runID = fieldRun.runID,
              let watchSessionID = activeWatchSessionID
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
            watchSessionID: watchSessionID,
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
        guard (phase == .running || phase == .finishing),
              fieldRun.phase == .running,
              acknowledgment.runID == fieldRun.runID,
              acknowledgment.watchSessionID == activeWatchSessionID,
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
        guard phase == .running || phase == .countdown else { return }

        // Freeze the classification boundary before any shutdown await.
        // Otherwise a slow Watch stop could make an early user stop appear
        // to have reached the 120 s protocol target.
        let finishRequestedElapsed = elapsedSeconds
        let reachedTarget =
            IndoBoardProductProtocol.reachedTarget(
                at: finishRequestedElapsed
            )

        countdownRemaining = nil
        phase = .finishing
        errorMessage = nil

        let stopRequested: Bool
        if let runID = fieldRun.runID,
           let watchSessionID = activeWatchSessionID {
            stopRequested = phone.sendWatchStopRequest(
                runID: runID,
                watchSessionID: watchSessionID
            )
        } else {
            stopRequested = false
        }

        camera.finishIndoCoachingSession()

        // Stop the camera immediately after issuing the Watch stop so
        // its media endpoint stays close to the 120 s product boundary.
        // Watch journal finalization can finish asynchronously afterward.
        if camera.phase == .recording {
            await camera.stopRecording()
        }

        var watchStopped = stopRequested
            ? await waitForWatchToLeaveRunning(phone: phone)
            : false

        if !watchStopped {
            watchStopped = watchCaptureStopped(phone)
        }

        if fieldRun.phase == .running || fieldRun.phase == .armed {
            let readiness = readinessSnapshot(
                phone: phone,
                camera: camera,
                pod: pod,
                runID: fieldRun.runID ?? "unknown"
            )

            if reachedTarget {
                fieldRun.seal(readiness: readiness)
            } else {
                fieldRun.abortRun(
                    reason: String(
                        format:
                            "Operator stopped the product session at %.1f s before the %.0f s target.",
                        finishRequestedElapsed,
                        IndoBoardProductProtocol
                            .targetDurationSeconds
                    ),
                    readiness: readiness
                )
            }
        }

        protocolTask?.cancel()
        protocolTask = nil
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        UIApplication.shared.isIdleTimerDisabled = false

        if fieldRun.phase == .sealed {
            do {
                outcome = reachedTarget ? .completed : .aborted
                productManifestURL = try writeProductManifest(
                    phone: phone,
                    camera: camera,
                    fieldRun: fieldRun
                )

                if watchStopped || watchCaptureStopped(phone) {
                    phase = .sealed
                    // Sync-window misses are represented structurally by the
                    // receipt count in the sealed summary, not as a stale
                    // transient error banner after a successful close.
                    errorMessage = nil
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
                let sourceDigest = try FileEvidence.digest(
                    sourceURL
                )

                let existingOriginals =
                    (try? manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ))?
                    .filter {
                        $0.lastPathComponent.hasPrefix("original-")
                    } ?? []

                let destination: URL
                if let existing = existingOriginals.first {
                    guard existingOriginals.count == 1 else {
                        throw ExternalVideoImportError
                            .conflictingExistingEvidence(
                                "multiple preserved originals"
                            )
                    }
                    let existingDigest = try FileEvidence.digest(
                        existing
                    )
                    guard existingDigest == sourceDigest else {
                        throw ExternalVideoImportError
                            .conflictingExistingEvidence(
                                existing.lastPathComponent
                            )
                    }
                    destination = existing
                } else {
                    destination = directory.appendingPathComponent(
                        "original-" + safeName
                    )
                    try manager.copyItem(
                        at: sourceURL,
                        to: destination
                    )
                }

                let digest = try FileEvidence.digest(destination)
                guard digest == sourceDigest else {
                    throw CocoaError(.fileReadCorruptFile)
                }
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
                    createdAtUTC: existing.createdAtUTC,
                    outcome: existing.outcome,
                    watchSessionID: existing.watchSessionID,
                    watchJournalSHA256: existing.watchJournalSHA256,
                    watchJournalByteCount: existing.watchJournalByteCount,
                    cameraSessionID: existing.cameraSessionID,
                    operatorJournalSHA256: existing.operatorJournalSHA256,
                    operatorMetadataSHA256: existing.operatorMetadataSHA256,
                    cameraVideoSHA256: existing.cameraVideoSHA256,
                    cameraJournalSHA256: existing.cameraJournalSHA256,
                    cameraMetadataSHA256: existing.cameraMetadataSHA256,
                    syncReceipts: existing.syncReceipts,
                    externalCameraExpected: existing.externalCameraExpected,
                    externalCameraImported: true,
                    externalCameraSHA256: evidence.sha256,
                    operatorEvidenceSealed: existing.operatorEvidenceSealed,
                    cameraEvidenceSealed: existing.cameraEvidenceSealed,
                    coachSummary: existing.coachSummary
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
        if watchCaptureStopped(phone) {
            phase = .sealed
            errorMessage = nil
        } else {
            errorMessage =
                SessionError.watchDidNotStop.localizedDescription
        }
    }

    func reset() {
        guard phase != .running
                && phase != .countdown
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
        sentProtocolCueIDs = []
        lastProtocolCueAttemptAt = [:]
        lastCueAttemptAt = [:]
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
        outcome = nil
        activeWatchSessionID = nil
        startedAt = nil
        countdownRemaining = nil
        cueReceipts = []
        pendingCueID = nil
        externalVideoEvidence = nil
        externalCameraConfirmed = false
        productManifestURL = nil
        errorMessage = nil
    }

    func instruction(
        at elapsed: TimeInterval
    ) -> String {
        IndoBoardProductProtocol.instruction(
            at: elapsed,
            acknowledgedSyncLabels: acknowledgedCueLabels
        )
    }

    private func startProtocolTimeline(
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        fieldRun: FieldRunCoordinator,
        pod: EquipmentPodController
    ) {
        protocolTask?.cancel()
        protocolTransitions = []

        advanceProtocol(
            elapsed: 0,
            phone: phone,
            fieldRun: fieldRun
        )

        protocolTask = Task { @MainActor [weak self, weak fieldRun] in
            while !Task.isCancelled {
                guard let self,
                      let fieldRun,
                      self.phase == .running
                else {
                    return
                }

                let elapsed = self.elapsedSeconds
                self.advanceProtocol(
                    elapsed: elapsed,
                    phone: phone,
                    fieldRun: fieldRun
                )

                if IndoBoardProductProtocol.reachedTarget(
                    at: elapsed
                ) {
                    Task { @MainActor [weak self, weak fieldRun] in
                        guard let self,
                              let fieldRun,
                              self.phase == .running
                        else {
                            return
                        }
                        await self.finish(
                            phone: phone,
                            camera: camera,
                            fieldRun: fieldRun,
                            pod: pod
                        )
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func advanceProtocol(
        elapsed: TimeInterval,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) {
        for block in IndoBoardProductProtocol.blocks {
            if elapsed >= block.endSeconds {
                transition(
                    "complete-\(block.id)",
                    when: true
                ) {
                    fieldRun.completeBlock(block.id)
                }
            } else if elapsed >= block.startSeconds {
                transition(
                    "start-\(block.id)",
                    when: true
                ) {
                    fieldRun.startBlock(block.id)
                }

                sendProtocolCueIfNeeded(
                    block,
                    phone: phone,
                    fieldRun: fieldRun
                )
            }
        }

        if !IndoBoardProductProtocol.reachedTarget(
            at: elapsed
        ) {
            for sync in IndoBoardProductProtocol.syncWindows {
                autoCue(
                    sync.label,
                    elapsed: elapsed,
                    target: sync.preferredSeconds,
                    windowEnd: sync.endSeconds,
                    phone: phone,
                    fieldRun: fieldRun
                )
            }
        }
    }

    private func sendProtocolCueIfNeeded(
        _ block: TimedProtocolBlock,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) {
        guard !sentProtocolCueIDs.contains(block.id),
              let runID = fieldRun.runID,
              let watchSessionID = activeWatchSessionID,
              phone.watchReachable
        else {
            return
        }

        let now = Date()
        if let previous = lastProtocolCueAttemptAt[block.id],
           now.timeIntervalSince(previous) < 2 {
            return
        }
        lastProtocolCueAttemptAt[block.id] = now

        if phone.sendSessionProtocolCue(
            runID: runID,
            watchSessionID: watchSessionID,
            stepID: block.id,
            title: block.title,
            instruction: block.instruction
        ) {
            sentProtocolCueIDs.insert(block.id)
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

    func watchWorkoutAccessReady(
        _ phone: PhoneSessionCoordinator
    ) -> Bool {
        phone.watchPresence?
            .healthAuthorization
            .lowercased() == "enabled"
    }

    func watchWorkoutAccessDetail(
        _ phone: PhoneSessionCoordinator
    ) -> String {
        phone.watchPresence?.healthAuthorization
            ?? "waiting for Watch status"
    }

    func watchCaptureAvailable(
        _ phone: PhoneSessionCoordinator
    ) -> Bool {
        switch phone.state {
        case .launchingWatch, .waitingForMirror, .running, .paused:
            return false
        default:
            break
        }

        guard let watchState = phone.watchPresence?
            .captureState
            .lowercased()
        else {
            return false
        }

        return [
            "idle",
            "journalready",
            "transferqueued",
            "transportcomplete",
            "transferred",
        ].contains(watchState)
    }

    func watchCaptureAvailabilityDetail(
        _ phone: PhoneSessionCoordinator
    ) -> String {
        guard let rawState = phone.watchPresence?.captureState else {
            return "waiting for Watch status"
        }

        switch rawState.lowercased() {
        case "idle", "transferred":
            return "ready"
        case "journalready", "transferqueued", "transportcomplete":
            return "ready · previous recording syncing"
        case "starting", "running", "paused", "ending":
            return "another recording is active"
        case "failed":
            return "resolve saved Watch evidence first"
        default:
            return rawState
        }
    }

    private func waitForFreshWatchSessionID(
        phone: PhoneSessionCoordinator,
        after launchRequestedAt: Date,
        excluding priorSessionID: String?,
        timeoutSeconds: TimeInterval = 10
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if let frame = phone.liveTelemetry.latest,
               frame.receivedAt >= launchRequestedAt,
               frame.snapshot.sessionID != priorSessionID,
               phone.state == .running || phone.state == .paused {
                return frame.snapshot.sessionID
            }

            if let presence = phone.watchPresence,
               let presenceSessionID = presence.sessionID,
               (presence.sourceSentAt ?? presence.receivedAt)
                    >= launchRequestedAt,
               !presenceSessionID.isEmpty,
               presenceSessionID != priorSessionID,
               ["running", "paused"].contains(
                    presence.captureState.lowercased()
               ),
               phone.state == .running || phone.state == .paused {
                return presenceSessionID
            }

            if phone.state == .failed
                || phone.state == .disconnected {
                return nil
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        return nil
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
            if watchCaptureStopped(phone) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return watchCaptureStopped(phone)
    }

    private func watchCaptureStopped(
        _ phone: PhoneSessionCoordinator
    ) -> Bool {
        if phone.state == .ended {
            return true
        }

        guard let captureState = phone.watchPresence?
            .captureState
            .lowercased()
        else {
            return false
        }

        return [
            "idle",
            "journalready",
            "transferqueued",
            "transportcomplete",
            "transferred",
            "failed",
        ].contains(captureState)
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
                activeWatchSessionID ?? "unknown",
            "iphone_camera_phase": camera.phase.rawValue,
            "iphone_camera_session_id":
                camera.sessionID ?? "unknown",
            "equipment_pod_phase": pod.phase.rawValue,
            "capture_mode": captureMode.rawValue,
            "pre_roll_countdown_seconds": "5",
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

        let operatorJournalDigest = try FileEvidence.digest(
            bundle.journalURL
        )
        let operatorMetadataDigest = try FileEvidence.digest(
            bundle.metadataURL
        )

        let cameraBundle = camera.evidenceBundle

        let latestWatchReceiptMatchesRun =
            phone.inbox.latestProductRunID == runID
                && phone.inbox.latestSessionID
                    == activeWatchSessionID

        let manifest = ProductSessionManifest(
            runID: runID,
            captureMode: captureMode.rawValue,
            targetDurationSeconds: Self.targetDurationSeconds,
            outcome: outcome ?? .completed,
            watchSessionID: activeWatchSessionID,
            watchJournalSHA256: latestWatchReceiptMatchesRun
                ? phone.inbox.latestJournalSHA256
                : nil,
            watchJournalByteCount: latestWatchReceiptMatchesRun
                ? phone.inbox.latestJournalByteCount
                : nil,
            cameraSessionID: camera.sessionID,
            operatorJournalSHA256: operatorJournalDigest.sha256,
            operatorMetadataSHA256: operatorMetadataDigest.sha256,
            cameraVideoSHA256: cameraBundle?.videoSHA256,
            cameraJournalSHA256: cameraBundle?.journalSHA256,
            cameraMetadataSHA256: cameraBundle?.metadataSHA256,
            syncReceipts: receipts,
            externalCameraExpected: externalCameraConfirmed,
            externalCameraImported: externalVideoEvidence != nil,
            externalCameraSHA256: externalVideoEvidence?.sha256,
            operatorEvidenceSealed: fieldRun.phase == .sealed,
            cameraEvidenceSealed: camera.phase == .evidenceReady,
            coachSummary: camera.indoCoachReport.map {
                ProductSessionManifest.CoachSummary(
                    headline: $0.headline,
                    observation: $0.observation,
                    tip: $0.tip,
                    drill: $0.drill,
                    confidence: $0.confidence,
                    evidenceLabel: $0.evidenceLabel,
                    metrics: Dictionary(
                        uniqueKeysWithValues: $0.metrics.map {
                            ($0.id, $0.value)
                        }
                    )
                )
            }
        )

        return try ProductSessionManifestStore.write(
            manifest,
            to: bundle.directory
        )
    }

    private func abortStart(
        error: SessionError,
        phone: PhoneSessionCoordinator,
        camera: CameraCaptureController,
        fieldRun: FieldRunCoordinator,
        pod: EquipmentPodController
    ) async {
        outcome = .aborted
        protocolTask?.cancel()
        protocolTask = nil
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        UIApplication.shared.isIdleTimerDisabled = false

        let runID = fieldRun.runID ?? "unknown"
        var watchStopped = true

        var stopRequested = false
        if phone.state == .running
            || phone.state == .paused
            || phone.state == .waitingForMirror
            || phone.state == .launchingWatch {
            watchStopped = false
            if fieldRun.runID != nil,
               let watchSessionID = activeWatchSessionID {
                stopRequested = phone.sendWatchStopRequest(
                    runID: runID,
                    watchSessionID: watchSessionID
                )
            }
            // Without a fresh Watch capture identity, do not send an
            // ambiguous remote-stop command into a possibly different run.
        }

        if camera.phase == .recording {
            await camera.stopRecording()
        }

        if stopRequested {
            watchStopped = await waitForWatchToLeaveRunning(
                phone: phone
            )
        }
        if !watchStopped {
            watchStopped = watchCaptureStopped(phone)
        }

        if fieldRun.phase == .armed
            || fieldRun.phase == .running {
            fieldRun.abortRun(
                reason: error.localizedDescription,
                readiness: readinessSnapshot(
                    phone: phone,
                    camera: camera,
                    pod: pod,
                    runID: runID
                )
            )
        }

        if fieldRun.phase == .sealed {
            productManifestURL = try? writeProductManifest(
                phone: phone,
                camera: camera,
                fieldRun: fieldRun
            )
        }

        if watchStopped && fieldRun.phase == .sealed {
            phase = .sealed
            errorMessage = nil
        } else if watchStopped {
            phase = .failed
            errorMessage = error.localizedDescription
        } else {
            phase = .watchStopRequired
            errorMessage = (
                error.localizedDescription
                    + " "
                    + SessionError.watchDidNotStop.localizedDescription
            )
        }
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
