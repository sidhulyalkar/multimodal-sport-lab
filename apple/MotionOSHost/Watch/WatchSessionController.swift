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

    private let motion = WatchMotionRecorder()
    private let workout = WatchWorkoutRecorder()
    private let transport = WatchConnectivityTransport()

    private var pipeline: WatchCapturePipeline?
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
    }

    func requestAuthorization() async {
        state = .authorizing
        errorMessage = nil

        do {
            try await workout.requestAuthorization()
            state = .idle
        } catch {
            fail(error)
        }
    }

    func start(configuration: HKWorkoutConfiguration) async {
        guard [
            CaptureState.idle,
            .journalReady,
            .transferred,
            .failed,
        ].contains(state) else {
            return
        }

        state = .starting
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

        let id = Self.makeSessionID()
        sessionID = id

        do {
            let url = try Self.makeJournalURL(sessionID: id)
            let pipeline = try WatchCapturePipeline(
                sessionID: id,
                journalURL: url
            )
            self.pipeline = pipeline

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
            eventCount = try await pipeline.append(metadataEvent)

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
                mirrorToCompanion: true
            )

            startedAt = Date()
            state = .running
        } catch {
            motion.stop()
            fail(error)
            await finalizeAndTransfer()
        }
    }

    func stop() {
        guard state == .running || state == .paused else { return }
        state = .ending
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
        guard let pipeline else { return }

        do {
            let count = try await pipeline.append(event)

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

            if count.isMultiple(of: 25) {
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
        heartRateBPM = bpm
        heartRateEventCount += 1
        guard let id = sessionID else { return }

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
        await record(event)
    }

    private func finalizeAndTransfer() async {
        guard !finalized else { return }
        finalized = true
        motion.stop()

        let shouldPreserveFailure = state == .failed

        guard let pipeline else {
            if !shouldPreserveFailure {
                state = .idle
            }
            return
        }

        do {
            eventCount = try await pipeline.close()
            let journalURL = pipeline.journalURL
            let id = pipeline.sessionID

            closedJournalURL = journalURL
            closedJournalEvidence = try FileEvidence.digest(journalURL)
            self.pipeline = nil

            if shouldPreserveFailure {
                return
            }

            state = .journalReady
            queueTransfer(
                journalURL: journalURL,
                sessionID: id
            )
        } catch {
            fail(error)
        }
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

        var message: [String: Any] = [
            "motionos_message": "watch_capture_health_v1",
            "session_id": id,
            "sent_at_unix_s": now.timeIntervalSince1970,
            "imu_sample_count": imuSampleCount,
            "hr_event_count": heartRateEventCount,
            "max_imu_gap_ms": maxIMUGapMS,
            "non_monotonic_imu_count": nonMonotonicIMUCount,
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
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
    }

    private static func makeSessionID() -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "p0-watch-\(timestamp)-\(UUID().uuidString.prefix(8).lowercased())"
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
