import XCTest
@testable import MotionOSAppleCapture

final class WatchSessionSummaryTests: XCTestCase {
    func testBuildsSummaryFromWatchJournal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var events: [SensorEnvelope] = []
        for sequence in 0..<251 {
            let t = UInt64(sequence) * 20_000_000
            events.append(
                SensorEnvelope(
                    sessionID: "summary-fixture",
                    deviceID: "apple-watch",
                    stream: "/body/watch/imu",
                    sequence: UInt64(sequence),
                    deviceTimeNS: t,
                    payload: [
                        "ax": .number(0),
                        "ay": .number(0),
                        "az": .number(9.80665),
                        "gx": .number(0.1),
                        "gy": .number(0.2),
                        "gz": .number(0.2),
                        "user_ax": .number(0.980665),
                        "user_ay": .number(0),
                        "user_az": .number(0),
                    ]
                )
            )
        }

        for sequence in 0..<3 {
            events.append(
                SensorEnvelope(
                    sessionID: "summary-fixture",
                    deviceID: "apple-watch",
                    stream: "/body/watch/hr",
                    sequence: UInt64(sequence),
                    deviceTimeNS: UInt64(sequence + 1) * 1_000_000_000,
                    payload: [
                        "bpm": .number(Double(90 + sequence * 10))
                    ]
                )
            )
        }

        try write(events, to: url)

        let summary = try WatchSessionSummaryBuilder.build(
            journalURL: url,
            sourceJournalSHA256: "abc123",
            bucketSeconds: 1
        )

        XCTAssertEqual(summary.protocolVersion, "motionos.watch-session-summary.v1")
        XCTAssertEqual(summary.sessionID, "summary-fixture")
        XCTAssertEqual(summary.sourceJournalSHA256, "abc123")
        XCTAssertEqual(summary.imu.count, 251)
        XCTAssertEqual(summary.imu.durationSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.effectiveHz, 50, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.maxGapMS, 20, accuracy: 1e-9)
        XCTAssertEqual(summary.imu.missingSequences, 0)
        XCTAssertEqual(summary.imu.nonMonotonicSequences, 0)
        XCTAssertEqual(summary.imu.nonMonotonicTimestamps, 0)
        XCTAssertEqual(summary.heartRate.count, 3)
        XCTAssertEqual(summary.heartRate.minimumBPM ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(summary.heartRate.meanBPM ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(summary.heartRate.maximumBPM ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(
            summary.motion.userAccelerationRMSG ?? 0,
            0.1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.motion.userAccelerationP95G ?? 0,
            0.1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            summary.motion.rotationRateRMSRadS ?? 0,
            0.3,
            accuracy: 1e-9
        )
        XCTAssertEqual(summary.trace.count, 6)
        XCTAssertTrue(summary.claimBoundary.contains("not raw evidence"))
    }

    func testSummaryTracksSequenceAndTimestampFailures() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-gap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let timestamps: [UInt64] = [
            0,
            20_000_000,
            10_000_000,
            60_000_000,
        ]
        let sequences: [UInt64] = [0, 1, 3, 2]

        let events = zip(sequences, timestamps).map { sequence, timestamp in
            SensorEnvelope(
                sessionID: "gap-fixture",
                deviceID: "apple-watch",
                stream: "/body/watch/imu",
                sequence: sequence,
                deviceTimeNS: timestamp,
                payload: [
                    "ax": .number(0),
                    "ay": .number(0),
                    "az": .number(9.80665),
                    "gx": .number(0),
                    "gy": .number(0),
                    "gz": .number(0),
                    "user_ax": .number(0),
                    "user_ay": .number(0),
                    "user_az": .number(0),
                ]
            )
        }

        try write(events, to: url)

        let summary = try WatchSessionSummaryBuilder.build(
            journalURL: url,
            sourceJournalSHA256: "gap"
        )

        XCTAssertEqual(summary.imu.missingSequences, 1)
        XCTAssertEqual(summary.imu.nonMonotonicSequences, 1)
        XCTAssertEqual(summary.imu.nonMonotonicTimestamps, 1)
        XCTAssertEqual(summary.imu.maxGapMS, 50, accuracy: 1e-9)
    }

    func testSummaryRejectsMixedSessions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-mixed-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let events = [
            SensorEnvelope(
                sessionID: "a",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 1,
                payload: [:]
            ),
            SensorEnvelope(
                sessionID: "b",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 2,
                payload: [:]
            ),
        ]
        try write(events, to: url)

        XCTAssertThrowsError(
            try WatchSessionSummaryBuilder.build(
                journalURL: url,
                sourceJournalSHA256: "mixed"
            )
        )
    }

    func testSummaryWriteRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-out-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = WatchSessionSummary(
            sessionID: "s1",
            sourceJournalSHA256: "hash",
            imu: .init(
                count: 10,
                durationSeconds: 1,
                effectiveHz: 9,
                maxGapMS: 20,
                missingSequences: 0,
                nonMonotonicSequences: 0,
                nonMonotonicTimestamps: 0
            ),
            heartRate: .init(
                count: 0,
                minimumBPM: nil,
                meanBPM: nil,
                maximumBPM: nil
            ),
            motion: .init(
                userAccelerationRMSG: 0.2,
                userAccelerationP95G: 0.3,
                rotationRateRMSRadS: 0.4,
                rotationRateP95RadS: 0.5
            ),
            trace: []
        )

        try WatchSessionSummaryBuilder.write(summary, to: url)
        let decoded = try JSONDecoder().decode(
            WatchSessionSummary.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(decoded, summary)
    }

    private func write(
        _ events: [SensorEnvelope],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}
