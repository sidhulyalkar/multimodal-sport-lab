import Combine
import Foundation
import HealthKit
import MotionOSAppleCapture
import WatchKit

@MainActor
final class WatchSessionController: ObservableObject {
    static let shared = WatchSessionController()

    enum CaptureState: String {
        case idle
        case authorizing
        case starting
        case running
        case paused
        case ending
        case journalReady
        case transferQueued
        case transportComplete
        case transferred
        case failed
    }

    enum CaptureOrigin: String {
        case iPhone = "iPhone"
        case localSensorCheck = "Watch test"
    }

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var sessionID: String?
    @Published private(set) var heartRateBPM: Double?
    @Published private(set) var eventCount = 0
    @Published private(set) var imuSampleCount: UInt64 = 0
    @Published private(set) var heartRateEventCount: UInt64 = 0
    @Published private(set) var observedIMUHz: Double?
    @Published private(set) var recentMedianIMUHz: Double?
    @Published private(set) var maxIMUGapMS: Double = 0
    @Published private(set) var nonMonotonicIMUCount: UInt64 = 0
    @Published private(set) var watchBatteryLevel: Double?
    @Published private(set) var guidedCueTitle: String?
    @Published private(set) var lastIMUSampleReceivedAt: Date?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastTransferredURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var phoneReachable = false
    @Published private(set) var companionAppInstalled = false
    @Published private(set) var connectivityActivated = false
    @Published private(set) var healthAuthorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published private(set) var captureOrigin: CaptureOrigin = .iPhone
    @Published private(set) var lastPresencePublishedAt: Date?
    /// Operator diagnostics for late, foreign, or stale events that were not
    /// journaled. Not raw evidence.
    @Published private(set) var captureRejections = CaptureRejectionCounts()

    private let motion = WatchMotionRecorder()
    private let workout = WatchWorkoutRecorder()
    private let transport = WatchConnectivityTransport()

    private var journal: CaptureSessionJournal?
    private var admission = CaptureEventAdmission()
    private var staleMotionRejectionBaseline: UInt64 = 0
    private var finalized = false
    private var heartRateSequence: UInt64 = 0
    private var closedJournalURL: URL?
    private var closedJournalEvidence: FileEvidenceDigest?
    private var imuHealth = SampleTimingHealth()
    private var lastTelemetrySentAt = Date.distantPast

    private init() {
        workout.onHeartRateBPM = { [weak self] bpm, timestamp in
            guard let self else { return }
            Task { @MainActor in
                await self.recordHeartRate(
                    bpm: bpm,
                    timestamp: timestamp
                )
            }
        }

        workout.onStateChange = { [weak self] workoutState in
            guard let self else { return }
            Task { @MainActor in
                self.applyWorkoutState(workoutState)
            }
        }

        workout.onWorkoutFinished = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.finalizeAndTransfer()
            }
        }

        transport.onStateChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshReadinessAndPresence()
            }
        }

        transport.onFileTransferFinished = {
            [weak self] url, metadata, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleTransferFinished(
                    url: url,
                    metadata: metadata,
                    error: error
                )
            }
        }

        transport.onUserInfoReceived = { [weak self] userInfo in
            guard let self else { return }
            Task { @MainActor in
                self.handleUserInfo(userInfo)
            }
        }

        transport.onMessageReceived = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleMessage(message)
            }
        }

        refreshReadinessAndPresence()
    }

    var healthAccessReady: Bool {
        healthAuthorizationStatus == .sharingAuthorized
    }

    var healthAuthorizationLabel: String {
        switch healthAuthorizationStatus {
        case .sharingAuthorized:
            "Enabled"
        case .sharingDenied:
            "Denied"
        case .notDetermined:
            "Needs access"
        @unknown default:
            "Unknown"
        }
    }

    var phoneLinkLabel: String {
        if phoneReachable {
            return "Connected"
        }
        if companionAppInstalled {
            return "Companion ready"
        }
        if connectivityActivated {
            return "Waiting for iPhone"
        }
        return "Starting link"
    }

    func applicationDidBecomeActive() {
        refreshReadinessAndPresence()
    }

    func requestAuthorization() async {
        state = .authorizing
        errorMessage = nil

        do {
            try await workout.requestAuthorization()
            healthAuthorizationStatus = workout.workoutAuthorizationStatus
            state = .idle
            publishPresence()
        } catch {
            healthAuthorizationStatus = workout.workoutAuthorizationStatus
            fail(error)
            publishPresence()
        }
    }

    func startLocalSensorCheck() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor
        await start(
            configuration: configuration,
            mirrorToCompanion: false,
            origin: .localSensorCheck,
            sessionPrefix: "smoke-watch"
        )
    }

    func start(
        configuration: HKWorkoutConfiguration,
        mirrorToCompanion: Bool = true,
        origin: CaptureOrigin = .iPhone,
        sessionPrefix: String = "p0-watch"
    ) async {
        guard [
            CaptureState.idle,
            .journalReady,
            .transferred,
            .failed,
        ].contains(state) else {
            return
        }

        state = .starting
        captureOrigin = origin
        errorMessage = nil
        heartRateBPM = nil
        eventCount = 0
        imuSampleCount = 0
        heartRateEventCount = 0
        observedIMUHz = nil
        recentMedianIMUHz = nil
        maxIMUGapMS = 0
        nonMonotonicIMUCount = 0
        watchBatteryLevel = nil
        guidedCueTitle = nil
        lastIMUSampleReceivedAt = nil
        heartRateSequence = 0
        finalized = false
        closedJournalURL = nil
        closedJournalEvidence = nil
        lastTransferredURL = nil
        imuHealth = SampleTimingHealth()
        lastTelemetrySentAt = .distantPast
        admission = CaptureEventAdmission()
        captureRejections = admission.rejections
        staleMotionRejectionBaseline = motion.staleCallbackRejectionCount

        let id = Self.makeSessionID(prefix: sessionPrefix)
        sessionID = id

        do {
            let url = try Self.makeJournalURL(sessionID: id)
            let journal = try CaptureSessionJournal(
                sessionID: id,
                url: url
            )
            self.journal = journal
            admission.begin(sessionID: id)

            let requestedMotionHz = 50.0
            let device = WKInterfaceDevice.current()
            device.isBatteryMonitoringEnabled = true
            let battery = device.batteryLevel
            watchBatteryLevel = battery >= 0
                ? Double(battery)
                : nil
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown"
            let appBuild = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"

            var watchMetadata: [String: JSONValue] = [
                "device_name": .string(device.name),
                "model": .string(device.model),
                "localized_model": .string(device.localizedModel),
                "system_name": .string(device.systemName),
                "system_version": .string(device.systemVersion),
                "requested_imu_hz": .number(requestedMotionHz),
                "app_version": .string(appVersion),
                "app_build": .string(appBuild),
                "wrist_location": .string(
                    device.wristLocation == .left ? "left" : "right"
                ),
                "crown_orientation": .string(
                    device.crownOrientation == .left ? "left" : "right"
                ),
            ]
            if let watchBatteryLevel {
                watchMetadata["battery_level_fraction"] =
                    .number(watchBatteryLevel)
            }

            let metadataEvent = SensorEnvelope(
                sessionID: id,
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: MonotonicClock.nowNS(),
                payload: watchMetadata
            )
            guard case .appended(let count) =
                    try await journal.append(metadataEvent)
            else {
                throw CaptureStartError.metadataNotJournaled
            }
            eventCount = count

            try motion.start(
                sessionID: id,
                deviceID: "apple-watch",
                hz: requestedMotionHz
            ) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    await self.record(event)
                }
            }

            try await workout.start(
                configuration: configuration,
                mirrorToCompanion: mirrorToCompanion
            )

            startedAt = Date()
            state = .running
            publishPresence()
        } catch {
            motion.stop()
            fail(error)
            await finalizeAndTransfer()
        }
    }

    func stop() {
        guard state == .running || state == .paused else { return }
        state = .ending
        publishPresence()
        motion.stop()
        workout.stop()
    }

    func pause() {
        guard state == .running else { return }
        workout.pause()
    }

    func resume() {
        guard state == .paused else { return }
        workout.resume()
    }

    func refreshReadinessAndPresence() {
        let session = transport.session
        connectivityActivated = session.activationState == .activated
        phoneReachable = connectivityActivated && session.isReachable
        #if os(watchOS)
        companionAppInstalled = connectivityActivated
            && session.isCompanionAppInstalled
        #endif
        healthAuthorizationStatus = workout.workoutAuthorizationStatus
        publishPresence()
    }

    func retryTransfer() {
        guard [
            CaptureState.journalReady,
            .transportComplete,
        ].contains(state),
        let journalURL = closedJournalURL,
        let id = sessionID
        else {
            return
        }

        queueTransfer(
            journalURL: journalURL,
            sessionID: id
        )
    }

    private func record(_ event: SensorEnvelope) async {
        guard let journal = admittedJournal(sessionID: event.sessionID) else {
            return
        }
        await append(event, to: journal)
    }

    /// The shutdown and cross-session boundary. Runs synchronously on the main
    /// actor, so once finalization begins no later callback reaches the
    /// journal. Rejections are counted, never treated as capture failures.
    private func admittedJournal(
        sessionID eventSessionID: String
    ) -> CaptureSessionJournal? {
        guard admission.admit(sessionID: eventSessionID) == nil else {
            refreshCaptureRejections()
            return nil
        }
        guard let journal else {
            admission.recordRejection(.noActiveSession)
            refreshCaptureRejections()
            return nil
        }
        return journal
    }

    private func append(
        _ event: SensorEnvelope,
        to journal: CaptureSessionJournal
    ) async {
        do {
            let outcome = try await journal.append(event)
            guard case .appended(let count) = outcome else {
                if case .rejected(let rejection) = outcome {
                    admission.recordRejection(rejection)
                    refreshCaptureRejections()
                }
                return
            }

            if event.stream == "/body/watch/imu" {
                imuHealth.observe(timestampNS: event.deviceTimeNS)
                imuSampleCount = imuHealth.sampleCount
                lastIMUSampleReceivedAt = Date()

                if imuHealth.sampleCount.isMultiple(of: 25) {
                    observedIMUHz = imuHealth.effectiveHz
                    recentMedianIMUHz = imuHealth.recentMedianHz
                    maxIMUGapMS = imuHealth.maxGapMS
                    nonMonotonicIMUCount =
                        imuHealth.nonMonotonicCount
                }
                publishCaptureHealthIfNeeded()
            }

            // finalizeAndTransfer() publishes the authoritative closed count.
            if admission.isCapturing, count.isMultiple(of: 25) {
                eventCount = count
            }
        } catch {
            fail(error)
        }
    }

    private func recordHeartRate(
        bpm: Double,
        timestamp: UInt64
    ) async {
        guard let id = sessionID else {
            admission.recordRejection(.noActiveSession)
            refreshCaptureRejections()
            return
        }
        // Admit before allocating a sequence so rejected late samples do not
        // consume one.
        guard let journal = admittedJournal(sessionID: id) else { return }

        heartRateBPM = bpm
        heartRateEventCount += 1
        let event = SensorEnvelope(
            sessionID: id,
            deviceID: "apple-watch",
            stream: "/body/watch/hr",
            sequence: heartRateSequence,
            deviceTimeNS: timestamp,
            sessionTimeNS: nil,
            syncQuality: nil,
            payload: ["bpm": .number(bpm)]
        )
        heartRateSequence += 1
        await append(event, to: journal)
    }

    private func finalizeAndTransfer() async {
        guard !finalized else { return }
        finalized = true
        motion.stop()

        // Shutdown boundary: before the first await, stop admitting events and
        // detach the journal. Appends admitted earlier are drained by close().
        admission.beginFinalizing()
        let journal = self.journal
        self.journal = nil

        let shouldPreserveFailure = state == .failed

        guard let journal else {
            admission.finish()
            refreshCaptureRejections()
            if !shouldPreserveFailure {
                state = .idle
            }
            return
        }

        do {
            eventCount = try await journal.close()
            admission.finish()
            refreshCaptureRejections()
            let journalURL = journal.url
            let id = journal.sessionID

            closedJournalURL = journalURL
            closedJournalEvidence = try FileEvidence.digest(journalURL)

            if shouldPreserveFailure {
                return
            }

            state = .journalReady
            queueTransfer(
                journalURL: journalURL,
                sessionID: id
            )
        } catch {
            admission.finish()
            refreshCaptureRejections()
            fail(error)
        }
    }

    private func refreshCaptureRejections() {
        admission.setStaleMotionGenerationCount(
            motion.staleCallbackRejectionCount
                &- staleMotionRejectionBaseline
        )
        captureRejections = admission.rejections
    }

    private func queueTransfer(
        journalURL: URL,
        sessionID: String
    ) {
        guard let evidence = closedJournalEvidence else {
            errorMessage = "Closed Watch journal has no verified digest."
            state = .journalReady
            return
        }

        let transfer = transport.transferJournal(
            journalURL,
            metadata: [
                "session_id": sessionID,
                "schema_version": "motionos.m0.v1",
                "stream": "/body/watch",
                "journal_sha256": evidence.sha256,
                "journal_byte_count": evidence.byteCount,
            ]
        )

        if transfer != nil {
            lastTransferredURL = journalURL
            errorMessage = nil
            state = .transferQueued
        } else {
            errorMessage = (
                "WatchConnectivity is not active yet. "
                + "The journal remains safe on Watch."
            )
            state = .journalReady
        }
    }

    private func handleTransferFinished(
        url: URL,
        metadata: [String: Any]?,
        error: Error?
    ) {
        guard let id = sessionID,
              metadata?["session_id"] as? String == id
        else {
            return
        }

        if let error {
            errorMessage = (
                "Journal transfer failed: "
                + error.localizedDescription
                + ". Source remains safe on Watch."
            )
            state = .journalReady
            return
        }

        if state != .transferred {
            state = .transportComplete
        }
    }

    private func handleMessage(
        _ message: [String: Any]
    ) {
        guard message["motionos_message"] as? String
                == "guided_protocol_cue_v1",
              let title = message["step_title"] as? String
        else {
            return
        }

        guidedCueTitle = title
        WKInterfaceDevice.current().play(.notification)
    }

    private func handleUserInfo(
        _ userInfo: [String: Any]
    ) {
        guard userInfo["motionos_message"] as? String
                == "journal_received_ack",
              let id = sessionID,
              userInfo["session_id"] as? String == id,
              let evidence = closedJournalEvidence,
              let receivedHash = userInfo["journal_sha256"] as? String
        else {
            return
        }

        guard receivedHash.lowercased() == evidence.sha256 else {
            errorMessage = (
                "iPhone receipt hash did not match the Watch journal. "
                + "Source remains safe on Watch."
            )
            state = .journalReady
            return
        }

        errorMessage = nil
        state = .transferred
    }

    private func publishCaptureHealthIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTelemetrySentAt) >= 2.0,
              let id = sessionID
        else {
            return
        }

        let device = WKInterfaceDevice.current()
        let battery = device.batteryLevel
        watchBatteryLevel = battery >= 0
            ? Double(battery)
            : nil
        refreshCaptureRejections()

        var message: [String: Any] = [
            "motionos_message": "watch_capture_health_v1",
            "session_id": id,
            "sent_at_unix_s": now.timeIntervalSince1970,
            "imu_sample_count": imuSampleCount,
            "hr_event_count": heartRateEventCount,
            "max_imu_gap_ms": maxIMUGapMS,
            "non_monotonic_imu_count": nonMonotonicIMUCount,
            // Additive diagnostics; older receivers ignore unknown keys.
            "rejected_after_shutdown_count":
                captureRejections.afterShutdown,
            "rejected_session_mismatch_count":
                captureRejections.sessionMismatch,
            "rejected_no_session_count":
                captureRejections.noActiveSession,
            "rejected_stale_motion_count":
                captureRejections.staleMotionGeneration,
        ]
        if let observedIMUHz {
            message["observed_imu_hz"] = observedIMUHz
        }
        if let recentMedianIMUHz {
            message["recent_median_imu_hz"] = recentMedianIMUHz
        }
        if let heartRateBPM {
            message["heart_rate_bpm"] = heartRateBPM
        }
        if let watchBatteryLevel {
            message["watch_battery_level_fraction"] =
                watchBatteryLevel
        }

        if transport.sendMessage(message) {
            lastTelemetrySentAt = now
        }
    }

    private func applyWorkoutState(
        _ workoutState: WatchWorkoutRecorder.State
    ) {
        switch workoutState {
        case .running:
            state = .running
        case .paused:
            state = .paused
        case .ending:
            state = .ending
        case .failed(let message):
            errorMessage = message
            state = .failed
        default:
            break
        }
        publishPresence()
    }

    private func publishPresence() {
        guard transport.session.activationState == .activated else {
            return
        }

        let device = WKInterfaceDevice.current()
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        var presence: [String: Any] = [
            "motionos_message": "watch_presence_v1",
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "app_version": appVersion,
            "app_build": appBuild,
            "watch_system_version": device.systemVersion,
            "capture_state": state.rawValue,
            "capture_origin": captureOrigin.rawValue,
            "health_authorization": healthAuthorizationLabel,
            "sent_at_unix_s": Date().timeIntervalSince1970,
        ]

        let battery = device.batteryLevel
        if battery >= 0 {
            presence["watch_battery_level_fraction"] = Double(battery)
        }

        let contextSent = transport.updateApplicationContext(presence)
        let liveSent = transport.sendMessage(presence)
        if contextSent || liveSent {
            lastPresencePublishedAt = Date()
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
        publishPresence()
    }

    private enum CaptureStartError: LocalizedError {
        case metadataNotJournaled

        var errorDescription: String? {
            "The Watch metadata event was not written to the new journal."
        }
    }

    private static func makeSessionID(prefix: String) -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "\(prefix)-\(timestamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func makeJournalURL(
        sessionID: String
    ) throws -> URL {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("MotionOS", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("watch.jsonl")
    }
}
