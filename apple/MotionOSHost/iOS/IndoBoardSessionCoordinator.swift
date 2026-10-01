import Combine
import Foundation

@MainActor
final class IndoBoardSessionCoordinator: ObservableObject {
    enum Phase: String {
        case idle
        case preparing
        case ready
        case starting
        case running
        case finishing
        case sealed
        case failed
    }

    enum SessionError: LocalizedError {
        case watchUnavailable
        case cameraUnavailable
        case insufficientBattery
        case insufficientStorage
        case watchDidNotStart
        case syncUnavailable
        case fieldRunUnavailable

        var errorDescription: String? {
            switch self {
            case .watchUnavailable:
                "The paired MotionOS Watch must be installed and reachable."
            case .cameraUnavailable:
                "Prepare the iPhone camera before starting the Indo Board session."
            case .insufficientBattery:
                "Charge the iPhone above the 20% development preflight margin."
            case .insufficientStorage:
                "Free at least 5 GB on the iPhone before recording."
            case .watchDidNotStart:
                "The Watch workout did not reach running state in time."
            case .syncUnavailable:
                "The Watch link is unavailable for a journal-backed sync cue."
            case .fieldRunUnavailable:
                "The operator run could not be armed."
            }
        }
    }

    struct CueReceipt: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let acknowledgedAt: Date
        let watchDeviceTimeNS: UInt64
    }

    static let targetDurationSeconds: TimeInterval = 120

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var cueReceipts: [CueReceipt] = []
    @Published private(set) var pendingCueID: String?
    @Published private(set) var errorMessage: String?
    @Published var externalCameraConfirmed = false

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
    }

    @discardableResult
    func emitSyncCue(
        label: String,
        phone: PhoneSessionCoordinator,
        fieldRun: FieldRunCoordinator
    ) -> String? {
        guard phase == .running,
              let runID = fieldRun.runID,
              phone.watchReachable
        else {
            fail(SessionError.syncUnavailable)
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
            fail(SessionError.syncUnavailable)
            return nil
        }

        pendingCueID = cueID
        errorMessage = nil
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

        if let runID = fieldRun.runID {
            _ = phone.sendWatchStopRequest(runID: runID)
        }

        _ = await waitForWatchToLeaveRunning(phone: phone)

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

        if fieldRun.phase == .sealed {
            phase = .sealed
        } else {
            fail(SessionError.fieldRunUnavailable)
        }
    }

    func reset() {
        guard phase != .running
                && phase != .starting
                && phase != .finishing
        else {
            return
        }
        phase = .idle
        startedAt = nil
        cueReceipts = []
        pendingCueID = nil
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
                : "Send START sync, then make one sharp arm gesture."
        case ..<45:
            "Natural free balance. Stay comfortable and visible to camera."
        case ..<55:
            acknowledgedCueLabels.contains("middle")
                ? "Return to neutral after the middle sync gesture."
                : "Send MIDDLE sync, then make one sharp arm gesture."
        case ..<90:
            "Five controlled tilt-and-recover cycles. Alternate directions."
        case ..<110:
            "Natural free balance, then settle toward neutral."
        case ..<120:
            acknowledgedCueLabels.contains("end")
                ? "Hold a comfortable neutral finish."
                : "Send END sync, then make one sharp arm gesture."
        default:
            "Session target reached. Finish and seal when stable."
        }
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
            "external_camera_confirmed":
                String(externalCameraConfirmed),
            "sync_acknowledged":
                cueReceipts.map(\.label).sorted().joined(separator: ","),
        ]
    }

    private func fail(_ error: Error) {
        phase = .failed
        errorMessage = error.localizedDescription
    }
}
