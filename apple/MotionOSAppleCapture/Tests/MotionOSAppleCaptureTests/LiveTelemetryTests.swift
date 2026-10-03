import XCTest
@testable import MotionOSAppleCapture

final class LiveTelemetryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Contract

    func testSnapshotRoundTripsThroughWatchConnectivityDictionary() throws {
        let snapshot = Self.snapshot(sequence: 7, heartRate: 121, battery: 0.6)
        let parsed = try LiveTelemetrySnapshot(message: snapshot.message)
        XCTAssertEqual(parsed, snapshot)
        XCTAssertTrue(
            PropertyListSerialization.propertyList(
                snapshot.message,
                isValidFor: .binary
            )
        )
    }

    func testAbsentSignalsAreOmittedNotZeroed() throws {
        let snapshot = Self.snapshot(
            sequence: 0,
            motion: nil,
            heartRate: nil,
            battery: nil,
            medianHz: nil
        )
        let message = snapshot.message
        for key in [
            "heart_rate_bpm",
            "watch_battery_fraction",
            "user_accel_peak_g",
            "roll_rad",
            "imu_recent_median_hz",
        ] {
            XCTAssertNil(message[key], key)
        }

        let parsed = try LiveTelemetrySnapshot(message: message)
        XCTAssertNil(parsed.heartRateBPM)
        XCTAssertNil(parsed.watchBatteryFraction)
        XCTAssertNil(parsed.motion)
        XCTAssertNil(parsed.recentMedianIMUHz)
    }

    func testParsingRejectsInvalidPayloadsSafely() {
        let valid = Self.snapshot(sequence: 3).message

        func rejects(
            _ mutate: (inout [String: Any]) -> Void,
            _ expected: LiveTelemetrySnapshot.ParseError,
            line: UInt = #line
        ) {
            var message = valid
            mutate(&message)
            XCTAssertThrowsError(
                try LiveTelemetrySnapshot(message: message),
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? LiveTelemetrySnapshot.ParseError,
                    expected,
                    line: line
                )
            }
        }

        rejects({ $0["motionos_message"] = "watch_capture_health_v1" }, .notLiveTelemetry)
        rejects({ $0["schema_version"] = 99 }, .unsupportedSchema)
        rejects({ $0["schema_version"] = nil }, .unsupportedSchema)
        rejects({ $0["session_id"] = nil }, .missingField("session_id"))
        rejects({ $0["session_id"] = "" }, .invalidField("session_id"))
        rejects({ $0["sequence"] = -1 }, .invalidField("sequence"))
        rejects({ $0["sequence"] = 1.5 }, .invalidField("sequence"))
        rejects({ $0["sequence"] = true }, .invalidField("sequence"))
        rejects({ $0["sequence"] = "3" }, .invalidField("sequence"))
        rejects({ $0["activity"] = "running" }, .invalidField("activity"))
        rejects({ $0["imu_max_gap_ms"] = Double.nan }, .invalidField("imu_max_gap_ms"))
        rejects({ $0["imu_recent_median_hz"] = Double.infinity }, .invalidField("imu_recent_median_hz"))
        rejects({ $0["heart_rate_bpm"] = 0.0 }, .invalidField("heart_rate_bpm"))
        rejects({ $0["watch_battery_fraction"] = 1.4 }, .invalidField("watch_battery_fraction"))
        rejects({ $0["recording_elapsed_s"] = -3.0 }, .invalidField("recording_elapsed_s"))
        rejects({ $0["user_accel_peak_g"] = nil }, .missingField("user_accel_peak_g"))
        rejects({ $0["user_accel_peak_g"] = -0.2 }, .invalidField("user_accel_peak_g"))
        rejects(
            {
                for key in [
                    "user_accel_peak_g",
                    "user_accel_latest_g",
                    "rotation_peak_rad_s",
                    "rotation_latest_rad_s",
                    "motion_window_samples",
                ] {
                    $0[key] = nil
                }
            },
            .invalidField("roll_rad")
        )
    }

    // MARK: - Buffer

    func testFirstPacketStartsSessionBuffer() {
        var buffer = LiveTelemetryBuffer()
        let outcome = buffer.ingest(Self.snapshot(sequence: 0), receivedAt: t0)
        XCTAssertEqual(outcome, .startedSession)
        XCTAssertEqual(buffer.sessionID, "s1")
        XCTAssertEqual(buffer.frames.count, 1)
        XCTAssertEqual(buffer.latest?.receivedAt, t0)
    }

    func testSameSessionPacketsAppend() {
        var buffer = LiveTelemetryBuffer()
        for sequence in 0..<5 {
            buffer.ingest(
                Self.snapshot(sequence: UInt64(sequence)),
                receivedAt: t0.addingTimeInterval(Double(sequence) * 0.25)
            )
        }
        XCTAssertEqual(buffer.frames.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(buffer.diagnostics.appended, 5)
    }

    func testDuplicateSequenceIgnored() {
        var buffer = LiveTelemetryBuffer()
        buffer.ingest(Self.snapshot(sequence: 4), receivedAt: t0)
        let outcome = buffer.ingest(
            Self.snapshot(sequence: 4),
            receivedAt: t0.addingTimeInterval(0.1)
        )
        XCTAssertEqual(outcome, .duplicate)
        XCTAssertEqual(buffer.frames.count, 1)
        XCTAssertEqual(buffer.latest?.receivedAt, t0)
        XCTAssertEqual(buffer.diagnostics.duplicates, 1)
    }

    func testOutOfOrderSequenceIgnored() {
        var buffer = LiveTelemetryBuffer()
        buffer.ingest(Self.snapshot(sequence: 10), receivedAt: t0)
        let outcome = buffer.ingest(
            Self.snapshot(sequence: 9),
            receivedAt: t0.addingTimeInterval(0.1)
        )
        XCTAssertEqual(outcome, .outOfOrder)
        XCTAssertEqual(buffer.frames.map(\.id), [10])

        buffer.ingest(Self.snapshot(sequence: 13), receivedAt: t0.addingTimeInterval(0.2))
        XCTAssertEqual(buffer.diagnostics.missingSequences, 2)
    }

    func testNewSessionClearsOldTraceAndRetiresIt() {
        var buffer = LiveTelemetryBuffer()
        buffer.ingest(Self.snapshot(sequence: 0, sessionID: "s1"), receivedAt: t0)
        buffer.ingest(Self.snapshot(sequence: 1, sessionID: "s1"), receivedAt: t0.addingTimeInterval(0.25))

        let started = buffer.ingest(
            Self.snapshot(sequence: 0, sessionID: "s2"),
            receivedAt: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(started, .startedSession)
        XCTAssertEqual(buffer.frames.map(\.snapshot.sessionID), ["s2"])

        // A late, in-flight packet from session 1 can never reappear.
        let late = buffer.ingest(
            Self.snapshot(sequence: 2, sessionID: "s1"),
            receivedAt: t0.addingTimeInterval(1.1)
        )
        XCTAssertEqual(late, .retiredSession)
        XCTAssertEqual(buffer.sessionID, "s2")
        XCTAssertEqual(buffer.frames.map(\.snapshot.sessionID), ["s2"])
    }

    func testBufferIsBoundedByTimeWindowAndCapacity() {
        var buffer = LiveTelemetryBuffer(retention: 60, capacity: 480)
        for sequence in 0..<2_000 {
            buffer.ingest(
                Self.snapshot(sequence: UInt64(sequence)),
                receivedAt: t0.addingTimeInterval(Double(sequence) * 0.25)
            )
        }
        let latest = try! XCTUnwrap(buffer.latest)
        let oldest = try! XCTUnwrap(buffer.frames.first)
        XCTAssertLessThanOrEqual(
            latest.receivedAt.timeIntervalSince(oldest.receivedAt),
            60
        )
        XCTAssertLessThanOrEqual(buffer.frames.count, 241)

        var tight = LiveTelemetryBuffer(retention: 600, capacity: 50)
        for sequence in 0..<500 {
            tight.ingest(Self.snapshot(sequence: UInt64(sequence)), receivedAt: t0)
        }
        XCTAssertEqual(tight.frames.count, 50)
        XCTAssertEqual(tight.frames.first?.id, 450)
    }

    // MARK: - Watch publisher

    func testPublisherNeverAttemptsMoreThanOncePerSlot() {
        var publisher = LiveTelemetryPublisher(interval: 0.25)
        publisher.begin(sessionID: "s1")
        var evaluations = 0
        var slots: [LiveTelemetryPublisher.Slot] = []

        // 10 s of 50 Hz IMU callbacks.
        for sample in 0..<500 {
            publisher.observe(Self.metrics(0.1), roll: 0, pitch: 0, yaw: 0)
            if let slot = publisher.takeSlot(
                at: Double(sample) * 0.02,
                channelAvailable: { evaluations += 1; return true }()
            ) {
                slots.append(slot)
            }
        }

        XCTAssertEqual(slots.count, 40)
        XCTAssertEqual(evaluations, 40)
        XCTAssertEqual(slots.map(\.sequence), Array(0..<40))
        XCTAssertTrue(slots.allSatisfy { ($0.motion?.windowSampleCount ?? 0) > 0 })
    }

    func testUnreachableChannelDropsInsteadOfRetrying() {
        var publisher = LiveTelemetryPublisher(interval: 0.25)
        publisher.begin(sessionID: "s1")
        var attempts = 0

        for sample in 0..<500 {
            publisher.observe(Self.metrics(sample == 10 ? 2.0 : 0.1), roll: nil, pitch: nil, yaw: nil)
            if publisher.takeSlot(
                at: Double(sample) * 0.02,
                channelAvailable: false
            ) != nil {
                attempts += 1
            }
        }
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(publisher.droppedUnavailableCount, 40)
        XCTAssertEqual(publisher.nextSequence, 0)

        // When the link returns, only new motion is sent: the 2 g spike from
        // the unreachable period was dropped with its slot.
        publisher.observe(Self.metrics(0.3), roll: nil, pitch: nil, yaw: nil)
        let slot = publisher.takeSlot(at: 10.5, channelAvailable: true)
        XCTAssertEqual(slot?.sequence, 0)
        XCTAssertEqual(slot?.motion?.userAccelerationPeakG, 0.3)
    }

    func testMotionWindowCapturesPeakBetweenSnapshots() {
        var window = LiveMotionWindow()
        for value in [0.1, 0.9, 0.2] {
            window.observe(Self.metrics(value), roll: 0.1, pitch: 0.2, yaw: 0.3)
        }
        let motion = window.drain()
        XCTAssertEqual(motion?.userAccelerationPeakG, 0.9)
        XCTAssertEqual(motion?.userAccelerationLatestG, 0.2)
        XCTAssertEqual(motion?.windowSampleCount, 3)
        XCTAssertNil(window.drain())
    }

    /// The live preview path and the journal are independent: dropping every
    /// preview packet leaves every IMU sample in the sealed journal.
    func testDisconnectedLivePreviewDoesNotAffectDurableRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionos-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try CaptureSessionJournal(
            sessionID: "s1",
            url: directory.appendingPathComponent("watch.jsonl")
        )
        var publisher = LiveTelemetryPublisher()
        publisher.begin(sessionID: "s1")

        for sequence in 0..<250 {
            let outcome = try await journal.append(
                SensorEnvelope(
                    sessionID: "s1",
                    deviceID: "apple-watch",
                    stream: "/body/watch/imu",
                    sequence: UInt64(sequence),
                    deviceTimeNS: UInt64(sequence) * 20_000_000,
                    payload: ["gx": .number(0), "gy": .number(0), "gz": .number(0)]
                )
            )
            XCTAssertEqual(outcome, .appended(count: sequence + 1))
            publisher.observe(Self.metrics(0.2), roll: nil, pitch: nil, yaw: nil)
            XCTAssertNil(
                publisher.takeSlot(
                    at: Double(sequence) * 0.02,
                    channelAvailable: false
                )
            )
        }

        let count = try await journal.close()
        XCTAssertEqual(count, 250)
        XCTAssertGreaterThan(publisher.droppedUnavailableCount, 0)
    }

    // MARK: - Observatory state

    func testFreshTelemetryIsLive() {
        let observation = resolve(
            presence: .init(capturePhase: .recording, sessionID: "s1", receivedAt: t0),
            frame: frame(sessionID: "s1", at: t0.addingTimeInterval(5)),
            now: t0.addingTimeInterval(5.5)
        )
        XCTAssertEqual(observation.observatory, .live)
        XCTAssertEqual(observation.link, .recording)
        XCTAssertEqual(observation.sessionFrame?.snapshot.sessionID, "s1")
    }

    func testStaleTelemetryChangesLiveToReconnecting() {
        let presence = WatchObservationInput.Presence(
            capturePhase: .recording,
            sessionID: "s1",
            receivedAt: t0
        )
        let latest = frame(sessionID: "s1", at: t0.addingTimeInterval(5))

        XCTAssertEqual(
            resolve(presence: presence, frame: latest, now: t0.addingTimeInterval(6)).observatory,
            .live
        )
        let stale = resolve(
            presence: presence,
            frame: latest,
            now: t0.addingTimeInterval(5 + WatchObservationResolver.liveFreshness + 0.1)
        )
        XCTAssertEqual(stale.observatory, .reconnecting)
        XCTAssertFalse(stale.observatory.isLive)
        XCTAssertTrue(stale.observatory.showsSessionTrace)
    }

    func testReopenedPhoneDuringRecordingWaitsForFreshPacket() {
        // The iPhone app relaunches: durable presence says recording, but no
        // packet has arrived yet, or only an old one.
        let presence = WatchObservationInput.Presence(
            capturePhase: .recording,
            sessionID: "s1",
            receivedAt: t0.addingTimeInterval(100)
        )
        XCTAssertEqual(
            resolve(presence: presence, frame: nil, now: t0.addingTimeInterval(100)).observatory,
            .reconnecting
        )
        XCTAssertEqual(
            resolve(
                presence: presence,
                frame: frame(sessionID: "s1", at: t0),
                now: t0.addingTimeInterval(100.2)
            ).observatory,
            .reconnecting
        )
        XCTAssertEqual(
            resolve(
                presence: presence,
                frame: frame(sessionID: "s1", at: t0.addingTimeInterval(100.5)),
                now: t0.addingTimeInterval(100.6)
            ).observatory,
            .live
        )
    }

    func testPausedCaptureCannotDisplayLive() {
        let pausedFrame = frame(sessionID: "s1", at: t0.addingTimeInterval(1), activity: .paused)
        XCTAssertEqual(
            resolve(
                presence: .init(capturePhase: .recording, sessionID: "s1", receivedAt: t0),
                frame: pausedFrame,
                now: t0.addingTimeInterval(1.1)
            ).observatory,
            .paused
        )
        // A newer paused presence overrides an older fresh "recording" frame.
        XCTAssertEqual(
            resolve(
                presence: .init(capturePhase: .paused, sessionID: "s1", receivedAt: t0.addingTimeInterval(2)),
                frame: frame(sessionID: "s1", at: t0.addingTimeInterval(1.9)),
                now: t0.addingTimeInterval(2.1)
            ).observatory,
            .paused
        )
    }

    func testStoppedCaptureCannotDisplayLive() {
        let finishing = WatchObservationInput.Presence(
            capturePhase: .finishing,
            sessionID: "s1",
            receivedAt: t0.addingTimeInterval(10)
        )
        // Even a fresh, late in-flight packet from the stopped session.
        let lateFrame = frame(sessionID: "s1", at: t0.addingTimeInterval(10.1))
        let observation = resolve(
            presence: finishing,
            frame: lateFrame,
            now: t0.addingTimeInterval(10.2)
        )
        XCTAssertEqual(observation.observatory, .finishing)

        let saved = resolve(
            presence: .init(capturePhase: .saved, sessionID: "s1", receivedAt: t0.addingTimeInterval(20)),
            frame: lateFrame,
            now: t0.addingTimeInterval(20.1)
        )
        XCTAssertEqual(saved.observatory, .saved)
        XCTAssertNil(saved.sessionFrame)
        XCTAssertEqual(saved.link, .ready)
    }

    func testNewSessionFramesNeverShowPreviousSession() {
        // Presence already announced session 2; the newest frame is still
        // from session 1.
        let observation = resolve(
            presence: .init(capturePhase: .recording, sessionID: "s2", receivedAt: t0.addingTimeInterval(1)),
            frame: frame(sessionID: "s1", at: t0.addingTimeInterval(0.9)),
            now: t0.addingTimeInterval(1.0)
        )
        XCTAssertEqual(observation.observatory, .reconnecting)
        XCTAssertNil(observation.sessionFrame)
    }

    func testAbsentHeartRateRemainsNil() throws {
        var buffer = LiveTelemetryBuffer()
        buffer.ingest(Self.snapshot(sequence: 0, heartRate: nil), receivedAt: t0)
        let observation = resolve(
            presence: nil,
            frame: buffer.latest,
            now: t0.addingTimeInterval(0.2)
        )
        XCTAssertEqual(observation.observatory, .live)
        XCTAssertNil(try XCTUnwrap(observation.sessionFrame).snapshot.heartRateBPM)
    }

    func testIdleWatchStatusLanguage() {
        func link(
            activated: Bool = true,
            paired: Bool = true,
            installed: Bool = true,
            reachable: Bool = false,
            recent: Bool = false,
            presence: WatchObservationInput.Presence? = nil
        ) -> WatchObservation {
            WatchObservationResolver.resolve(
                WatchObservationInput(
                    now: t0,
                    connectivityActivated: activated,
                    paired: paired,
                    systemAppInstalled: installed,
                    reachable: reachable,
                    presenceRecent: recent,
                    presence: presence,
                    mirroredWorkout: .none,
                    latestFrame: nil
                )
            )
        }

        XCTAssertEqual(link(activated: false).link, .checking)
        XCTAssertEqual(link(activated: false).observatory, .checking)
        XCTAssertEqual(link(paired: false).link, .noWatch)
        XCTAssertEqual(link(paired: false).observatory, .watchSetupRequired)
        XCTAssertEqual(link(installed: false).link, .appSetup(needsInstall: true))
        XCTAssertEqual(link().link, .appSetup(needsInstall: false))
        XCTAssertEqual(link(recent: true).link, .ready)
        XCTAssertEqual(link(recent: true).observatory, .ready)
        XCTAssertEqual(link(reachable: true).link, .ready)
        XCTAssertEqual(
            link(
                recent: true,
                presence: .init(capturePhase: .failed, sessionID: "s1", receivedAt: t0)
            ).link,
            .issue
        )
    }

    func testMirroredLaunchShowsStarting() {
        let observation = WatchObservationResolver.resolve(
            WatchObservationInput(
                now: t0,
                connectivityActivated: true,
                paired: true,
                systemAppInstalled: true,
                reachable: true,
                presenceRecent: true,
                presence: .init(capturePhase: .idle, sessionID: nil, receivedAt: t0),
                mirroredWorkout: .launching,
                latestFrame: nil
            )
        )
        XCTAssertEqual(observation.observatory, .starting)
        XCTAssertEqual(observation.link, .recording)
    }

    func testUnresponsiveRecordingBecomesIssue() {
        let observation = resolve(
            presence: .init(capturePhase: .recording, sessionID: "s1", receivedAt: t0),
            frame: nil,
            now: t0.addingTimeInterval(WatchObservationResolver.unresponsiveAfter + 1)
        )
        XCTAssertEqual(observation.observatory, .issue)
    }

    func testPresenceCaptureStateMapping() {
        XCTAssertEqual(WatchCapturePhase(presenceCaptureState: "running"), .recording)
        XCTAssertEqual(WatchCapturePhase(presenceCaptureState: "ending"), .finishing)
        XCTAssertEqual(WatchCapturePhase(presenceCaptureState: "transferQueued"), .saved)
        XCTAssertEqual(WatchCapturePhase(presenceCaptureState: "nonsense"), .unknown)
    }

    // MARK: - Helpers

    private func resolve(
        presence: WatchObservationInput.Presence?,
        frame: LiveTelemetryFrame?,
        now: Date
    ) -> WatchObservation {
        WatchObservationResolver.resolve(
            WatchObservationInput(
                now: now,
                connectivityActivated: true,
                paired: true,
                systemAppInstalled: true,
                reachable: true,
                presenceRecent: true,
                presence: presence,
                mirroredWorkout: .none,
                latestFrame: frame
            )
        )
    }

    private func frame(
        sessionID: String,
        at date: Date,
        activity: LiveTelemetrySnapshot.Activity = .recording
    ) -> LiveTelemetryFrame {
        LiveTelemetryFrame(
            snapshot: Self.snapshot(sequence: 1, sessionID: sessionID, activity: activity),
            receivedAt: date
        )
    }

    private static func metrics(_ acceleration: Double) -> WatchMotionDerivedMetrics {
        WatchMotionDerivedMetrics(
            userAccelerationG: acceleration,
            rotationRateRadS: acceleration * 2
        )
    }

    private static func snapshot(
        sequence: UInt64,
        sessionID: String = "s1",
        activity: LiveTelemetrySnapshot.Activity = .recording,
        motion: LiveTelemetrySnapshot.Motion? = LiveTelemetrySnapshot.Motion(
            userAccelerationPeakG: 0.31,
            userAccelerationLatestG: 0.12,
            rotationRatePeakRadS: 2.4,
            rotationRateLatestRadS: 1.1,
            rollRadians: 0.2,
            pitchRadians: -0.4,
            yawRadians: 1.2,
            windowSampleCount: 12
        ),
        heartRate: Double? = 118,
        battery: Double? = 0.8,
        medianHz: Double? = 49.9
    ) -> LiveTelemetrySnapshot {
        LiveTelemetrySnapshot(
            sessionID: sessionID,
            sequence: sequence,
            sourceMonotonicNS: 1_000_000 + sequence * 250_000_000,
            sourceSentAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
            activity: activity,
            elapsedSeconds: 30 + Double(sequence) * 0.25,
            imuSampleCount: 100 + sequence * 12,
            effectiveIMUHz: 49.8,
            recentMedianIMUHz: medianHz,
            maxIMUGapMS: 24,
            nonMonotonicIMUCount: 0,
            motion: motion,
            heartRateBPM: heartRate,
            watchBatteryFraction: battery
        )
    }
}
