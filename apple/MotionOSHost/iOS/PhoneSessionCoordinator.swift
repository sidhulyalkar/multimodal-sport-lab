import Combine
import Foundation
import HealthKit
import MotionOSAppleCapture
import UIKit
import WatchConnectivity

struct SessionSyncAcknowledgment: Equatable, Sendable {
    let runID: String
    let cueID: String
    let label: String
    let watchSessionID: String
    let watchDeviceTimeNS: UInt64
    let receivedAt: Date
}

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
    let userAccelerationG: Double?
    let rotationRateRadS: Double?
    let rollRadians: Double?
    let pitchRadians: Double?
    let yawRadians: Double?
}

struct WatchTelemetryPoint: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let sessionID: String
    let imuHz: Double?
    let maxGapMS: Double
    let heartRateBPM: Double?
    let userAccelerationG: Double?
    let rotationRateRadS: Double?
    let rollRadians: Double?
    let pitchRadians: Double?
    let yawRadians: Double?
}

struct WatchPresence: Equatable, Sendable {
    let receivedAt: Date
    let sourceSentAt: Date?
    let bundleID: String
    let appVersion: String
    let appBuild: String
    let watchSystemVersion: String
    let captureState: String
    let captureOrigin: String
    let sessionID: String?
    let healthAuthorization: String
    let phonePresenceConfirmed: Bool
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
    @Published private(set) var systemWatchAppInstalled = false
    @Published private(set) var watchReachable = false
    @Published private(set) var watchCaptureHealth: WatchLiveCaptureHealth?
    @Published private(set) var watchPresence: WatchPresence?
    @Published private(set) var watchTelemetryHistory: [WatchTelemetryPoint] = []
    @Published private(set) var lastSessionSyncAcknowledgment:
        SessionSyncAcknowledgment?
    @Published private(set) var iPhoneBatteryLevel: Double?
    @Published private(set) var iPhoneAvailableStorageBytes: Int64?
    @Published private(set) var errorMessage: String?

    let inbox = PhoneJournalInbox()

    private let healthStore = HKHealthStore()
    private let transport = WatchConnectivityTransport()
    private var mirroredSession: HKWorkoutSession?
    private var batteryObservers: [NSObjectProtocol] = []
    private var lastWatchPresenceRequestAt = Date.distantPast
    private let watchPresenceRequestMinimumInterval: TimeInterval = 5

    override init() {
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true
        installHostReadinessObservers()

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
                defer {
                    try? FileManager.default.removeItem(at: url)
                }
                if let receipt = self.inbox.ingest(
                    fileURL: url,
                    metadata: metadata
                ) {
                    self.acknowledgeJournal(receipt)
                }
            }
        }

        transport.onApplicationContextReceived = { [weak self] context in
            guard let self else { return }
            Task { @MainActor in
                self.ingestWatchPresence(context)
                self.refreshWatchState()
            }
        }

        transport.onUserInfoReceived = { [weak self] userInfo in
            guard let self else { return }
            Task { @MainActor in
                self.ingestWatchPresence(userInfo)
                self.refreshWatchState()
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
        let activated = session.activationState == .activated

        if !activated {
            // A deactivation can mean the user switched active Watches.
            // Never carry a prior Watch's handshake into the new session.
            watchPresence = nil
            watchCaptureHealth = nil
            watchTelemetryHistory = []
        } else {
            ingestWatchPresence(session.receivedApplicationContext)
            publishPhonePresence()
        }

        // WCSession's install bit can lag a development install. A current
        // MotionOS presence packet or live reachability is stronger evidence
        // that the counterpart app exists on the active paired Watch.
        watchPaired = activated && session.isPaired
        watchReachable = activated && session.isReachable
        systemWatchAppInstalled = activated && session.isWatchAppInstalled
        watchAppInstalled = activated
            && (
                systemWatchAppInstalled
                    || hasRecentWatchPresence()
                    || session.isReachable
            )

        requestWatchPresenceIfNeeded()
        refreshHostReadiness()
    }

    private func installHostReadinessObservers() {
        for name in [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHostReadiness()
                    self?.refreshWatchState()
                }
            }
            batteryObservers.append(observer)
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.refreshHostReadiness()
        }
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

    @discardableResult
    func sendSessionProtocolCue(
        runID: String,
        watchSessionID: String,
        stepID: String,
        title: String,
        instruction: String
    ) -> Bool {
        transport.sendMessage(
            [
                "motionos_message": "session_protocol_cue_v1",
                "run_id": runID,
                "watch_session_id": watchSessionID,
                "step_id": stepID,
                "step_title": title,
                "instruction": instruction,
            ]
        )
    }

    @discardableResult
    func sendWatchStopRequest(
        runID: String,
        watchSessionID: String
    ) -> Bool {
        transport.sendMessage(
            [
                "motionos_message": "session_stop_request_v1",
                "run_id": runID,
                "watch_session_id": watchSessionID,
            ]
        )
    }

    @discardableResult
    func sendSessionSyncCue(
        runID: String,
        watchSessionID: String,
        cueID: String,
        label: String
    ) -> Bool {
        transport.sendMessage(
            [
                "motionos_message": "session_sync_cue_v1",
                "run_id": runID,
                "watch_session_id": watchSessionID,
                "cue_id": cueID,
                "label": label,
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

    func watchPresenceAge(
        at date: Date = Date()
    ) -> TimeInterval? {
        guard let watchPresence else { return nil }
        let timestamp = watchPresence.sourceSentAt ?? watchPresence.receivedAt
        return max(0, date.timeIntervalSince(timestamp))
    }

    func hasRecentWatchPresence(
        at date: Date = Date(),
        maxAge: TimeInterval = 600
    ) -> Bool {
        guard let age = watchPresenceAge(at: date) else { return false }
        return age <= maxAge
    }

    var watchConnectionLabel: String {
        if state == .running || state == .paused {
            return "Watch recording"
        }
        if watchConnectionReady {
            return "Watch ready"
        }
        if watchPaired {
            return "Watch app setup"
        }
        return "No Watch"
    }

    var watchConnectionDetail: String {
        if watchReachable {
            return "MotionOS detected now"
        }
        if hasRecentWatchPresence() {
            return "MotionOS detected recently"
        }
        if systemWatchAppInstalled {
            return "Open MotionOS on the Watch once"
        }
        if watchPaired {
            return "Install or open MotionOS on the Watch"
        }
        return "Pair an Apple Watch with this iPhone"
    }

    var watchConnectionReady: Bool {
        watchPaired
            && (
                watchReachable
                    || hasRecentWatchPresence()
            )
    }

    var watchTwoWayLinkVerified: Bool {
        hasRecentWatchPresence()
            && (watchPresence?.phonePresenceConfirmed == true)
    }

    private func requestWatchPresenceIfNeeded(
        at date: Date = Date()
    ) {
        guard watchReachable,
              date.timeIntervalSince(lastWatchPresenceRequestAt)
                >= watchPresenceRequestMinimumInterval
        else {
            return
        }

        let sent = transport.sendMessage(
            [
                "motionos_message": "watch_presence_request_v1",
                "sent_at_unix_s": date.timeIntervalSince1970,
            ]
        )
        if sent {
            lastWatchPresenceRequestAt = date
        }
    }

    private func ingestWatchMessage(
        _ message: [String: Any]
    ) {
        let type = message["motionos_message"] as? String

        if type == "phone_presence_request_v1" {
            publishPhonePresence()
            return
        }

        if type == "watch_presence_v1" {
            ingestWatchPresence(message)
            refreshWatchState()
            return
        }

        if type == "session_sync_cue_ack_v1" {
            guard let runID = message["run_id"] as? String,
                  let cueID = message["cue_id"] as? String,
                  let label = message["label"] as? String,
                  let watchSessionID =
                    message["watch_session_id"] as? String,
                  let watchDeviceTimeNS = Self.uint64(
                    message["watch_device_time_ns"]
                  )
            else {
                return
            }

            lastSessionSyncAcknowledgment = SessionSyncAcknowledgment(
                runID: runID,
                cueID: cueID,
                label: label,
                watchSessionID: watchSessionID,
                watchDeviceTimeNS: watchDeviceTimeNS,
                receivedAt: Date()
            )
            return
        }

        guard type == "watch_capture_health_v1",
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

        let receivedAt = Date()
        let previousSessionID = watchCaptureHealth?.sessionID
        let userAccelerationG = Self.double(message["user_acceleration_g"])
        let rotationRateRadS = Self.double(
            message["rotation_rate_rad_s"]
        )
        let rollRadians = Self.double(message["device_roll_rad"])
        let pitchRadians = Self.double(message["device_pitch_rad"])
        let yawRadians = Self.double(message["device_yaw_rad"])
        let heartRateBPM = Self.double(message["heart_rate_bpm"])
        let recentMedianIMUHz = Self.double(
            message["recent_median_imu_hz"]
        )

        if previousSessionID != nil && previousSessionID != sessionID {
            watchTelemetryHistory = []
        }

        watchCaptureHealth = WatchLiveCaptureHealth(
            sessionID: sessionID,
            receivedAt: receivedAt,
            sourceSentAt: sentAt,
            imuSampleCount: imuSamples,
            heartRateEventCount: hrEvents,
            observedIMUHz: Self.double(
                message["observed_imu_hz"]
            ),
            recentMedianIMUHz: recentMedianIMUHz,
            maxIMUGapMS: maxGap,
            nonMonotonicIMUCount: nonMonotonic,
            heartRateBPM: heartRateBPM,
            watchBatteryLevel: Self.double(
                message["watch_battery_level_fraction"]
            ),
            userAccelerationG: userAccelerationG,
            rotationRateRadS: rotationRateRadS,
            rollRadians: rollRadians,
            pitchRadians: pitchRadians,
            yawRadians: yawRadians
        )

        watchTelemetryHistory.append(
            WatchTelemetryPoint(
                timestamp: sentAt ?? receivedAt,
                sessionID: sessionID,
                imuHz: recentMedianIMUHz,
                maxGapMS: maxGap,
                heartRateBPM: heartRateBPM,
                userAccelerationG: userAccelerationG,
                rotationRateRadS: rotationRateRadS,
                rollRadians: rollRadians,
                pitchRadians: pitchRadians,
                yawRadians: yawRadians
            )
        )
        if watchTelemetryHistory.count > 120 {
            watchTelemetryHistory.removeFirst(
                watchTelemetryHistory.count - 120
            )
        }
    }

    private func publishPhonePresence() {
        guard transport.session.activationState == .activated else {
            return
        }

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        let message: [String: Any] = [
            "motionos_message": "phone_presence_v1",
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "app_version": version,
            "app_build": build,
            "workout_state": state.rawValue,
            "sent_at_unix_s": Date().timeIntervalSince1970,
        ]

        _ = transport.updateApplicationContext(message)
        _ = transport.sendMessage(message)
    }

    private func ingestWatchPresence(
        _ message: [String: Any]
    ) {
        guard message["motionos_message"] as? String == "watch_presence_v1",
              let bundleID = message["bundle_id"] as? String,
              bundleID == "com.sidhulyalkar.motionos.watchkitapp"
        else {
            return
        }

        let sentAt = Self.double(message["sent_at_unix_s"]).map {
            Date(timeIntervalSince1970: $0)
        }

        watchPresence = WatchPresence(
            receivedAt: Date(),
            sourceSentAt: sentAt,
            bundleID: bundleID,
            appVersion: message["app_version"] as? String ?? "unknown",
            appBuild: message["app_build"] as? String ?? "unknown",
            watchSystemVersion:
                message["watch_system_version"] as? String ?? "unknown",
            captureState: message["capture_state"] as? String ?? "unknown",
            captureOrigin: message["capture_origin"] as? String ?? "unknown",
            sessionID: message["session_id"] as? String,
            healthAuthorization:
                message["health_authorization"] as? String ?? "unknown",
            phonePresenceConfirmed:
                message["phone_presence_confirmed"] as? Bool ?? false,
            watchBatteryLevel:
                Self.double(message["watch_battery_level_fraction"])
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

    func startP0(
        locationType: HKWorkoutSessionLocationType = .outdoor
    ) async {
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
        configuration.locationType = locationType

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
