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

    struct VisualTelemetryPoint: Identifiable, Equatable, Sendable {
        let id = UUID()
        let timestamp: Date
        let userAccelerationG: Double
        let rotationRateRadS: Double
        let imuHz: Double?
        let heartRateBPM: Double?
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
    @Published private(set) var phonePresenceConfirmed = false
    @Published private(set) var companionAppInstalled = false
    @Published private(set) var connectivityActivated = false
    @Published private(set) var healthAuthorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published private(set) var captureOrigin: CaptureOrigin = .iPhone
    @Published private(set) var lastPresencePublishedAt: Date?
    @Published private(set) var userAccelerationG: Double?
    @Published private(set) var rotationRateRadS: Double?
    @Published private(set) var deviceRollRadians: Double?
    @Published private(set) var devicePitchRadians: Double?
    @Published private(set) var deviceYawRadians: Double?
    @Published private(set) var visualTelemetryHistory: [VisualTelemetryPoint] = []
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
    private var sessionSyncSequence: UInt64 = 0
    private var productCueTitle: String?
    private var linkedProductRunID: String?
    private var rejectedProductControlCount: UInt64 = 0
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

        transport.onApplicationContextReceived = { [weak self] context in
            guard let self else { return }
            Task { @MainActor in
                self.ingestPhonePresence(context)
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
                if !self.ingestPhonePresence(message) {
                    self.handleMessage(message)
                }
            }
        }

        refreshReadinessAndPresence()
    }

    var healthAccessReady: Bool {
        healthAuthorizationStatus == .sharingAuthorized
    }

    var hasRecoverableJournal: Bool {
        closedJournalURL != nil && closedJournalEvidence != nil
    }

    var canStartCapture: Bool {
        if state == .idle || state == .transferred {
            return true
        }
        if state == .failed {
            return journal == nil && !hasRecoverableJournal
        }
        return false
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
        if phonePresenceConfirmed {
            return "Handshake seen"
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
        guard canStartCapture else {
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
        userAccelerationG = nil
        rotationRateRadS = nil
        deviceRollRadians = nil
        devicePitchRadians = nil
        deviceYawRadians = nil
        visualTelemetryHistory = []
        heartRateSequence = 0
        sessionSyncSequence = 0
        productCueTitle = nil
        linkedProductRunID = nil
        rejectedProductControlCount = 0
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
                "capture_origin": .string(origin.rawValue),
                "workout_mirrored_to_companion": .bool(mirrorToCompanion),
                "hr_timestamp_semantics":
                    .string("callback_arrival_monotonic"),
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
            WKInterfaceDevice.current().play(.start)
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
        WKInterfaceDevice.current().play(.stop)
        publishPresence()
        motion.stop()
        workout.stop()
    }

    func pause() {
        guard state == .running else { return }
        WKInterfaceDevice.current().play(.click)
        workout.pause()
    }

    func resume() {
        guard state == .paused else { return }
        WKInterfaceDevice.current().play(.click)
        workout.resume()
    }

    func refreshReadinessAndPresence() {
        let session = transport.session
        connectivityActivated = session.activationState == .activated
        phoneReachable = connectivityActivated && session.isReachable

        if connectivityActivated {
            _ = ingestPhonePresence(session.receivedApplicationContext)
        }

        #if os(watchOS)
        companionAppInstalled = connectivityActivated
            && (session.isCompanionAppInstalled || phonePresenceConfirmed)
        #endif

        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel
        watchBatteryLevel = battery >= 0 ? Double(battery) : nil

        healthAuthorizationStatus = workout.workoutAuthorizationStatus
        publishPresence()
    }

    @discardableResult
    private func ingestPhonePresence(
        _ message: [String: Any]
    ) -> Bool {
        guard message["motionos_message"] as? String == "phone_presence_v1",
              message["bundle_id"] as? String == "com.sidhulyalkar.motionos"
        else {
            return false
        }

        phonePresenceConfirmed = true
        if transport.session.activationState == .activated {
            #if os(watchOS)
            companionAppInstalled =
                transport.session.isCompanionAppInstalled
                    || phonePresenceConfirmed
            #endif
        }
        return true
    }

    func retryTransfer() {
        guard (
            state == .journalReady
                || state == .transportComplete
                || (state == .failed && hasRecoverableJournal)
        ),
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

    @discardableResult
    private func record(_ event: SensorEnvelope) async -> Bool {
        guard let journal = admittedJournal(sessionID: event.sessionID) else {
            return false
        }
        return await append(event, to: journal)
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

    @discardableResult
    private func append(
        _ event: SensorEnvelope,
        to journal: CaptureSessionJournal
    ) async -> Bool {
        do {
            let outcome = try await journal.append(event)
            guard case .appended(let count) = outcome else {
                if case .rejected(let rejection) = outcome {
                    admission.recordRejection(rejection)
                    refreshCaptureRejections()
                }
                return false
            }

            if event.stream == "/body/watch/imu" {
                imuHealth.observe(timestampNS: event.deviceTimeNS)
                imuSampleCount = imuHealth.sampleCount
                lastIMUSampleReceivedAt = Date()
                updateVisualTelemetry(from: event)

                if imuHealth.sampleCount.isMultiple(of: 25) {
                    observedIMUHz = imuHealth.effectiveHz
                    recentMedianIMUHz = imuHealth.recentMedianHz
                    maxIMUGapMS = imuHealth.maxGapMS
                    nonMonotonicIMUCount =
                        imuHealth.nonMonotonicCount
                    appendVisualTelemetryPoint()
                }
                publishCaptureHealthIfNeeded()
            }

            // finalizeAndTransfer() publishes the authoritative closed count.
            if admission.isCapturing, count.isMultiple(of: 25) {
                eventCount = count
            }
            return true
        } catch {
            fail(error)
            return false
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
            payload: [
                "bpm": .number(bpm),
                "source": .string("healthkit_live_workout_builder"),
                "timestamp_semantics":
                    .string("callback_arrival_monotonic"),
            ]
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

        let preservingCaptureFailure = state == .failed
        let priorError = errorMessage

        var transferMetadata: [String: Any] = [
            "session_id": sessionID,
            "schema_version": "motionos.m0.v1",
            "stream": "/body/watch",
            "journal_sha256": evidence.sha256,
            "journal_byte_count": evidence.byteCount,
            "capture_origin": captureOrigin.rawValue,
            "rejected_after_shutdown_count":
                captureRejections.afterShutdown,
            "rejected_session_mismatch_count":
                captureRejections.sessionMismatch,
            "rejected_no_session_count":
                captureRejections.noActiveSession,
            "rejected_stale_motion_count":
                captureRejections.staleMotionGeneration,
            "rejected_product_control_count":
                rejectedProductControlCount,
        ]
        if let linkedProductRunID {
            transferMetadata["product_run_id"] = linkedProductRunID
        }

        let transfer = transport.transferJournal(
            journalURL,
            metadata: transferMetadata
        )

        if transfer != nil {
            lastTransferredURL = journalURL
            if !preservingCaptureFailure {
                errorMessage = nil
            }
            state = .transferQueued
        } else {
            let transferMessage = (
                "WatchConnectivity is not active yet. "
                + "The journal remains safe on Watch."
            )
            errorMessage = preservingCaptureFailure
                ? [priorError, transferMessage]
                    .compactMap { $0 }
                    .joined(separator: " ")
                : transferMessage
            state = preservingCaptureFailure ? .failed : .journalReady
        }
        publishPresence()
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
        publishPresence()
    }

    private func handleMessage(
        _ message: [String: Any]
    ) {
        guard let type = message["motionos_message"] as? String else {
            return
        }

        switch type {
        case "guided_protocol_cue_v1":
            guard let title = message["step_title"] as? String else {
                return
            }
            guidedCueTitle = title
            WKInterfaceDevice.current().play(.notification)

        case "session_protocol_cue_v1":
            guard state == .running || state == .paused,
                  let runID = message["run_id"] as? String,
                  bindProductRunID(runID),
                  let title = message["step_title"] as? String
            else {
                return
            }
            productCueTitle = title
            guidedCueTitle = title
            WKInterfaceDevice.current().play(.notification)

        case "session_stop_request_v1":
            guard state == .running || state == .paused,
                  let runID = message["run_id"] as? String,
                  bindProductRunID(runID)
            else {
                return
            }
            productCueTitle = nil
            guidedCueTitle = "FINISHING"
            WKInterfaceDevice.current().play(.stop)
            stop()

        case "session_sync_cue_v1":
            guard state == .running || state == .paused,
                  let runID = message["run_id"] as? String,
                  bindProductRunID(runID),
                  let cueID = message["cue_id"] as? String,
                  let label = message["label"] as? String,
                  let watchSessionID = sessionID
            else {
                return
            }

            let timestamp = MonotonicClock.nowNS()
            let event = SensorEnvelope(
                sessionID: watchSessionID,
                deviceID: "apple-watch",
                stream: "/sync/session_cue",
                sequence: sessionSyncSequence,
                deviceTimeNS: timestamp,
                payload: [
                    "run_id": .string(runID),
                    "cue_id": .string(cueID),
                    "label": .string(label),
                    "timing_semantics":
                        .string("watch_monotonic_receive_time"),
                ]
            )
            sessionSyncSequence &+= 1

            Task { @MainActor [weak self] in
                guard let self,
                      await self.record(event)
                else {
                    return
                }

                self.guidedCueTitle = "SYNC · MOVE NOW"
                WKInterfaceDevice.current().play(.notification)

                let acknowledgment: [String: Any] = [
                    "motionos_message": "session_sync_cue_ack_v1",
                    "run_id": runID,
                    "cue_id": cueID,
                    "label": label,
                    "watch_session_id": watchSessionID,
                    "watch_device_time_ns": timestamp,
                ]
                _ = self.transport.sendMessage(acknowledgment)
                _ = self.transport.queueUserInfo(acknowledgment)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1_500))
                    guard let self,
                          self.guidedCueTitle == "SYNC · MOVE NOW"
                    else {
                        return
                    }
                    self.guidedCueTitle = self.productCueTitle
                }
            }

        default:
            return
        }
    }

    @discardableResult
    private func bindProductRunID(
        _ runID: String
    ) -> Bool {
        guard !runID.isEmpty else {
            rejectedProductControlCount &+= 1
            return false
        }

        if let linkedProductRunID {
            guard linkedProductRunID == runID else {
                rejectedProductControlCount &+= 1
                return false
            }
            return true
        }

        linkedProductRunID = runID
        return true
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
        WKInterfaceDevice.current().play(.success)
        publishPresence()
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
        if let userAccelerationG {
            message["user_acceleration_g"] = userAccelerationG
        }
        if let rotationRateRadS {
            message["rotation_rate_rad_s"] = rotationRateRadS
        }
        if let deviceRollRadians {
            message["device_roll_rad"] = deviceRollRadians
        }
        if let devicePitchRadians {
            message["device_pitch_rad"] = devicePitchRadians
        }
        if let deviceYawRadians {
            message["device_yaw_rad"] = deviceYawRadians
        }

        if transport.sendMessage(message) {
            lastTelemetrySentAt = now
        }
    }

    private func updateVisualTelemetry(
        from event: SensorEnvelope
    ) {
        guard let derived = WatchMotionDerivation.derive(
            payload: event.payload
        )
        else {
            return
        }

        userAccelerationG = derived.userAccelerationG
        rotationRateRadS = derived.rotationRateRadS
        deviceRollRadians = number(event.payload["roll"])
        devicePitchRadians = number(event.payload["pitch"])
        deviceYawRadians = number(event.payload["yaw"])
    }

    private func appendVisualTelemetryPoint() {
        guard let userAccelerationG,
              let rotationRateRadS
        else {
            return
        }

        visualTelemetryHistory.append(
            VisualTelemetryPoint(
                timestamp: Date(),
                userAccelerationG: userAccelerationG,
                rotationRateRadS: rotationRateRadS,
                imuHz: recentMedianIMUHz,
                heartRateBPM: heartRateBPM
            )
        )

        if visualTelemetryHistory.count > 48 {
            visualTelemetryHistory.removeFirst(
                visualTelemetryHistory.count - 48
            )
        }
    }

    private func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value else {
            return nil
        }
        return number
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
        WKInterfaceDevice.current().play(.failure)
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
