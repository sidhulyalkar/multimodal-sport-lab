import Combine
import Foundation
import HealthKit
import MotionOSAppleCapture
import UIKit
import WatchConnectivity

struct WatchLiveCaptureHealth: Equatable, Sendable {
    let sessionID: String
    let receivedAt: Date
    let sourceSentAt: Date?
    let imuSampleCount: UInt64
    let heartRateEventCount: UInt64
    let observedIMUHz: Double?
    let recentMedianIMUHz: Double?
    let maxIMUGapMS: Double
    let nonMonotonicIMUCount: UInt64
    let heartRateBPM: Double?
    let watchBatteryLevel: Double?
}

@MainActor
final class PhoneSessionCoordinator: NSObject, ObservableObject {
    enum State: String {
        case idle
        case authorizing
        case launchingWatch
        case waitingForMirror
        case running
        case paused
        case disconnected
        case ended
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var watchPaired = false
    @Published private(set) var watchAppInstalled = false
    @Published private(set) var watchReachable = false
    @Published private(set) var watchCaptureHealth: WatchLiveCaptureHealth?
    @Published private(set) var iPhoneBatteryLevel: Double?
    @Published private(set) var iPhoneAvailableStorageBytes: Int64?
    @Published private(set) var errorMessage: String?

    let inbox = PhoneJournalInbox()

    private let healthStore = HKHealthStore()
    private let transport = WatchConnectivityTransport()
    private var mirroredSession: HKWorkoutSession?

    override init() {
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true

        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            guard let self else { return }
            Task { @MainActor in
                self.adoptMirroredSession(session)
            }
        }

        transport.onStateChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshWatchState()
            }
        }

        transport.onFileReceived = { [weak self] url, metadata in
            guard let self else { return }
            // WCSession's received file URL is temporary, so verify/copy it
            // while handling the callback rather than retaining the source URL.
            Task { @MainActor in
                if let receipt = self.inbox.ingest(
                    fileURL: url,
                    metadata: metadata
                ) {
                    self.acknowledgeJournal(receipt)
                }
            }
        }

        transport.onMessageReceived = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.ingestWatchMessage(message)
            }
        }

        refreshWatchState()
    }

    func refreshWatchState() {
        let session = transport.session
        watchPaired = session.isPaired
        watchAppInstalled = session.isWatchAppInstalled
        watchReachable = session.isReachable
        refreshHostReadiness()
    }

    func refreshHostReadiness() {
        let battery = UIDevice.current.batteryLevel
        iPhoneBatteryLevel = battery >= 0
            ? Double(battery)
            : nil

        do {
            let attributes = try FileManager.default
                .attributesOfFileSystem(forPath: NSHomeDirectory())
            if let free = attributes[.systemFreeSize] as? NSNumber {
                iPhoneAvailableStorageBytes = free.int64Value
            } else {
                iPhoneAvailableStorageBytes = nil
            }
        } catch {
            iPhoneAvailableStorageBytes = nil
        }
    }

    @discardableResult
    func sendGuidedProtocolCue(
        plan: GuidedProtocolPlan,
        step: GuidedProtocolStep
    ) -> Bool {
        transport.sendMessage(
            [
                "motionos_message": "guided_protocol_cue_v1",
                "plan_id": plan.id,
                "plan_version": plan.version,
                "step_id": step.id,
                "step_title": step.title,
            ]
        )
    }

    func watchCaptureHealthAge(
        at date: Date = Date()
    ) -> TimeInterval? {
        guard let watchCaptureHealth else { return nil }
        return max(
            0,
            date.timeIntervalSince(watchCaptureHealth.receivedAt)
        )
    }

    private func ingestWatchMessage(
        _ message: [String: Any]
    ) {
        guard message["motionos_message"] as? String
                == "watch_capture_health_v1",
              let sessionID = message["session_id"] as? String,
              let imuSamples = Self.uint64(
                message["imu_sample_count"]
              ),
              let hrEvents = Self.uint64(
                message["hr_event_count"]
              ),
              let maxGap = Self.double(
                message["max_imu_gap_ms"]
              ),
              let nonMonotonic = Self.uint64(
                message["non_monotonic_imu_count"]
              )
        else {
            return
        }

        let sentAt = Self.double(message["sent_at_unix_s"]).map {
            Date(timeIntervalSince1970: $0)
        }

        watchCaptureHealth = WatchLiveCaptureHealth(
            sessionID: sessionID,
            receivedAt: Date(),
            sourceSentAt: sentAt,
            imuSampleCount: imuSamples,
            heartRateEventCount: hrEvents,
            observedIMUHz: Self.double(
                message["observed_imu_hz"]
            ),
            recentMedianIMUHz: Self.double(
                message["recent_median_imu_hz"]
            ),
            maxIMUGapMS: maxGap,
            nonMonotonicIMUCount: nonMonotonic,
            heartRateBPM: Self.double(
                message["heart_rate_bpm"]
            ),
            watchBatteryLevel: Self.double(
                message["watch_battery_level_fraction"]
            )
        )
    }

    private func acknowledgeJournal(
        _ receipt: JournalIngestReceipt
    ) {
        let acknowledgment: [String: Any] = [
            "motionos_message": "journal_received_ack",
            "session_id": receipt.sessionID,
            "journal_sha256": receipt.journalSHA256,
            "journal_byte_count": receipt.byteCount,
        ]

        // Immediate message improves operator feedback when reachable.
        // transferUserInfo remains the durable background acknowledgment.
        _ = transport.sendMessage(acknowledgment)
        _ = transport.queueUserInfo(acknowledgment)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            let signed = value.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    func requestAuthorization() async {
        state = .authorizing
        errorMessage = nil
        do {
            let workout = HKObjectType.workoutType()
            let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)
            var read: Set<HKObjectType> = [workout]
            if let heartRate { read.insert(heartRate) }

            try await healthStore.requestAuthorization(
                toShare: [workout],
                read: read
            )
            state = .idle
        } catch {
            fail(error)
        }
    }

    func startP0() async {
        errorMessage = nil
        refreshWatchState()

        guard watchPaired else {
            fail(CoordinatorError.watchNotPaired)
            return
        }
        guard watchAppInstalled else {
            fail(CoordinatorError.watchAppNotInstalled)
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        state = .launchingWatch
        do {
            try await healthStore.startWatchApp(toHandle: configuration)
            state = .waitingForMirror
        } catch {
            fail(error)
        }
    }

    private func adoptMirroredSession(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = self
        switch session.state {
        case .running:
            state = .running
        case .paused:
            state = .paused
        case .ended:
            state = .ended
        default:
            state = .waitingForMirror
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
    }

    enum CoordinatorError: LocalizedError {
        case watchNotPaired
        case watchAppNotInstalled

        var errorDescription: String? {
            switch self {
            case .watchNotPaired:
                "No paired Apple Watch is available."
            case .watchAppNotInstalled:
                "Install MotionOS on the paired Apple Watch first."
            }
        }
    }
}

extension PhoneSessionCoordinator: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:
                self.state = .running
            case .paused:
                self.state = .paused
            case .ended:
                self.state = .ended
                self.mirroredSession = nil
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.fail(error)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            self.state = .disconnected
            if let error {
                self.errorMessage = error.localizedDescription
            }
            self.mirroredSession = nil
        }
    }
}
