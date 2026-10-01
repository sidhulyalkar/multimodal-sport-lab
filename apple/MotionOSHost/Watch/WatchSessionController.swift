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
    @Published private(set) var productCueInstruction: String?
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
    @Published private(set) var rejectedProductControlCount: UInt64 = 0
    @Published private(set) var pendingTransferCount = 0

    private struct PendingJournalTransfer {
        let url: URL
        let evidence: FileEvidenceDigest
        let metadata: [String: Any]
    }

    private var pendingJournalTransfers: [String: PendingJournalTransfer] = [:]
    private var closedJournalURL: URL?
    private var closedJournalEvidence: FileEvidenceDigest?
    private var imuHealth = SampleTimingHealth()
    private var lastTelemetrySentAt = Date.distantPast
    private var lastTransferQueueAttemptAt = Date.distantPast
    private var lastPhonePresenceRequestAt = Date.distantPast
    private let automaticTransferRetryInterval: TimeInterval = 15
    private let phonePresenceRequestMinimumInterval: TimeInterval = 5

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
        guard let id = sessionID else {
            return closedJournalURL != nil && closedJournalEvidence != nil
        }
        return pendingJournalTransfers[id] != nil
            || (closedJournalURL != nil && closedJournalEvidence != nil)
    }

    var canStartCapture: Bool {
        switch state {
        case .idle, .journalReady, .transferQueued,
                .transportComplete, .transferred:
            return true
        case .failed:
            return journal == nil
        default:
            return false
        }
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
        if phoneReachable || phonePresenceConfirmed {
            return "Ready"
        }
        if companionAppInstalled {
            return "Installed"
        }
        if connectivityActivated {
            return "Open iPhone app"
        }
        return "Starting"
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
        productCueInstruction = nil
        linkedProductRunID = nil
        rejectedProductControlCount = 0
        finalized = false
        closedJournalURL = nil
        closedJournalEvidence = nil
        lastTransferredURL = nil
        imuHealth = SampleTimingHealth()
        lastTelemetrySentAt = .distantPast
        lastTransferQueueAttemptAt = .distantPast
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
        requestPhonePresenceIfNeeded()
        retryPendingTransfersIfNeeded()
    }

    private func requestPhonePresenceIfNeeded(
        at date: Date = Date()
    ) {
        guard phoneReachable,
              date.timeIntervalSince(lastPhonePresenceRequestAt)
                >= phonePresenceRequestMinimumInterval
        else {
            return
        }

        if transport.sendMessage(
            [
                "motionos_message": "phone_presence_request_v1",
                "sent_at_unix_s": date.timeIntervalSince1970,
            ]
        ) {
            lastPhonePresenceRequestAt = date
        }
    }

    private func retryPendingTransfersIfNeeded(
        at date: Date = Date()
    ) {
        guard connectivityActivated,
              !pendingJournalTransfers.isEmpty,
              date.timeIntervalSince(lastTransferQueueAttemptAt)
                >= automaticTransferRetryInterval
        else {
            return
        }

        lastTransferQueueAttemptAt = date
        for (id, pending) in pendingJournalTransfers {
            queueTransfer(
                journalURL: pending.url,
                sessionID: id
            )
        }
    }

    func dismissCompletedCapture() {
        guard state == .journalReady
                || state == .transferQueued
                || state == .transportComplete
                || state == .transferred
        else {
            return
        }

        closedJournalURL = nil
        closedJournalEvidence = nil
        lastTransferredURL = nil
        sessionID = nil
        startedAt = nil
        errorMessage = nil
        state = .idle
        publishPresence()
    }

    @discardableResult
    func deleteCurrentRecording() -> Bool {
        guard state != .running,
              state != .paused,
              state != .starting,
              state != .ending,
              let id = sessionID
        else {
            return false
        }

        _ = transport.cancelJournalTransfers(sessionID: id)

        let journalURL =
            pendingJournalTransfers[id]?.url
                ?? closedJournalURL
        if let journalURL {
            let directory = journalURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: directory)
        }

        pendingJournalTransfers.removeValue(forKey: id)
        pendingTransferCount = pendingJournalTransfers.count

        closedJournalURL = nil
        closedJournalEvidence = nil
        lastTransferredURL = nil
        sessionID = nil
        startedAt = nil
        errorMessage = nil
        state = .idle
        publishPresence()
        return true
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
        guard state == .journalReady
                || state == .transferQueued
                || state == .transportComplete
                || (state == .failed && hasRecoverableJournal),
              let id = sessionID,
              let journalURL =
                pendingJournalTransfers[id]?.url
                    ?? closedJournalURL
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
            registerPendingJournal(
                journalURL: journalURL,
                sessionID: id
            )

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

    private func registerPendingJournal(
        journalURL: URL,
        sessionID: String
    ) {
        guard let evidence = closedJournalEvidence else {
            return
        }
        guard pendingJournalTransfers[sessionID] == nil else {
            return
        }

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

        pendingJournalTransfers[sessionID] = PendingJournalTransfer(
            url: journalURL,
            evidence: evidence,
            metadata: transferMetadata
        )
        pendingTransferCount = pendingJournalTransfers.count
    }

    private func queueTransfer(
        journalURL: URL,
        sessionID: String
    ) {
        if pendingJournalTransfers[sessionID] == nil {
            registerPendingJournal(
                journalURL: journalURL,
                sessionID: sessionID
            )
        }

        guard let pending = pendingJournalTransfers[sessionID] else {
            if self.sessionID == sessionID {
                errorMessage = "Closed Watch journal has no verified digest."
                state = .journalReady
            }
            return
        }

        lastTransferQueueAttemptAt = Date()
        let visibleSession = self.sessionID == sessionID
            && state != .running
            && state != .paused
            && state != .starting
            && state != .ending
        let preservingCaptureFailure = visibleSession && state == .failed
        let priorError = errorMessage

        let transfer = transport.transferJournal(
            pending.url,
            metadata: pending.metadata
        )

        if transfer != nil {
            if visibleSession {
                lastTransferredURL = pending.url
                if !preservingCaptureFailure {
                    errorMessage = nil
                    state = .transferQueued
                }
            }
        } else if visibleSession {
            let transferMessage = (
                "The recording is safe on this Watch and will retry "
                + "when the iPhone link is available."
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
        guard let id = metadata?["session_id"] as? String,
              pendingJournalTransfers[id] != nil
        else {
            return
        }

        let visibleSession = sessionID == id
            && state != .running
            && state != .paused
            && state != .starting
            && state != .ending

        if let error {
            if visibleSession {
                errorMessage = (
                    "The iPhone transfer paused: "
                    + error.localizedDescription
                    + ". The recording is still safe on Watch."
                )
                state = .journalReady
                publishPresence()
            }
            return
        }

        if visibleSession && state != .transferred {
            state = .transportComplete
            errorMessage = nil
            publishPresence()
        }
    }

    private func handleMessage(
        _ message: [String: Any]
    ) {
        guard let type = message["motionos_message"] as? String else {
            return
        }

        switch type {
        case "watch_presence_request_v1":
            publishPresence()

        case "phone_presence_request_v1":
            // This request is intended for iPhone and is harmless if echoed.
            return

        case "guided_protocol_cue_v1":
            guard let title = message["step_title"] as? String else {
                return
            }
            guidedCueTitle = title
            WKInterfaceDevice.current().play(.notification)

        case "session_protocol_cue_v1":
            guard state == .running || state == .paused,
                  validateProductControlSession(message),
                  let runID = message["run_id"] as? String,
                  bindProductRunID(runID),
                  let title = message["step_title"] as? String
            else {
                return
            }
            productCueTitle = title
            productCueInstruction =
                message["instruction"] as? String
            guidedCueTitle = title
            WKInterfaceDevice.current().play(.click)

        case "session_stop_request_v1":
            guard state == .running || state == .paused,
                  validateProductControlSession(message),
                  let runID = message["run_id"] as? String,
                  bindProductRunID(runID)
            else {
                return
            }
            productCueTitle = nil
            productCueInstruction = nil
            guidedCueTitle = "FINISHING"
            WKInterfaceDevice.current().play(.stop)
            stop()

        case "session_sync_cue_v1":
            guard state == .running || state == .paused,
                  validateProductControlSession(message),
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
                WKInterfaceDevice.current().play(.directionUp)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    WKInterfaceDevice.current().play(.click)
                }

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

    private func validateProductControlSession(
        _ message: [String: Any]
    ) -> Bool {
        guard let currentSessionID = sessionID,
              let targetSessionID =
                message["watch_session_id"] as? String,
              targetSessionID == currentSessionID
        else {
            rejectedProductControlCount &+= 1
            return false
        }
        return true
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
              let id = userInfo["session_id"] as? String,
              let pending = pendingJournalTransfers[id],
              let receivedHash = userInfo["journal_sha256"] as? String
        else {
            return
        }

        let visibleSession = sessionID == id
            && state != .running
            && state != .paused
            && state != .starting
            && state != .ending

        guard receivedHash.lowercased() == pending.evidence.sha256 else {
            if visibleSession {
                errorMessage = (
                    "The iPhone receipt did not match this recording. "
                    + "The Watch copy has been kept."
                )
                state = .journalReady
                publishPresence()
            }
            return
        }

        releaseVerifiedLocalJournal(
            sessionID: id,
            journalURL: pending.url
        )
        pendingJournalTransfers.removeValue(forKey: id)
        pendingTransferCount = pendingJournalTransfers.count

        if visibleSession {
            errorMessage = nil
            state = .transferred
            closedJournalURL = nil
            closedJournalEvidence = nil
            WKInterfaceDevice.current().play(.success)
            publishPresence()
        }
    }

    private func releaseVerifiedLocalJournal(
        sessionID: String,
        journalURL: URL
    ) {
        // The iPhone has re-hashed this exact journal and returned the
        // matching digest. Only now is the Watch copy eligible for deletion.
        let sessionDirectory = journalURL.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: sessionDirectory)
        } catch {
            // Cleanup failure must not invalidate an already verified receipt.
        }
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

        if let sessionID {
            presence["session_id"] = sessionID
        }

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
