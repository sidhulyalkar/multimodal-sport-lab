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
        case transferred
        case failed
    }

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var sessionID: String?
    @Published private(set) var heartRateBPM: Double?
    @Published private(set) var eventCount = 0
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
        heartRateSequence = 0
        finalized = false
        closedJournalURL = nil
        lastTransferredURL = nil

        let id = Self.makeSessionID()
        sessionID = id

        do {
            let url = try Self.makeJournalURL(sessionID: id)
            let pipeline = try WatchCapturePipeline(
                sessionID: id,
                journalURL: url
            )
            self.pipeline = pipeline

            try motion.start(
                sessionID: id,
                deviceID: "apple-watch",
                hz: 50
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
        guard let journalURL = closedJournalURL,
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
        let transfer = transport.transferJournal(
            journalURL,
            metadata: [
                "session_id": sessionID,
                "schema_version": "motionos.m0.v1",
                "stream": "/body/watch",
            ]
        )

        if transfer != nil {
            lastTransferredURL = journalURL
            state = .transferred
        } else {
            state = .journalReady
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
