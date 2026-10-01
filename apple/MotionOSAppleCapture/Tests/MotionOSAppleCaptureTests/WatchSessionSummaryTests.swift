import Foundation
import Testing
@testable import MotionOSAppleCapture

struct WatchSessionSummaryTests {
    @Test
    func summarizesMotionHeartRateAndContinuity() throws {
        let url = try makeJournal(
            sampleCount: 201,
            hz: 50,
            missingSequence: nil
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try WatchSessionSummaryAnalyzer.summarizeJournal(
            at: url
        )

        #expect(summary.sessionID == "review-fixture")
        #expect(summary.captureOrigin == "Watch test")
        #expect(summary.imuSampleCount == 201)
        #expect(summary.heartRateEventCount == 3)
        #expect(abs(summary.durationSeconds - 4.0) < 0.001)
        #expect(abs(summary.effectiveIMUHz - 50.0) < 0.01)
        #expect(summary.missingIMUSequences == 0)
        #expect(summary.nonMonotonicIMUTimestamps == 0)
        #expect((summary.maxIMUMilliseconds - 20.0).magnitude < 0.01)
        #expect(summary.motionDeltaGP95 != nil)
        #expect(summary.rotationRateP95RadS != nil)
        #expect(summary.heartRateMedianBPM == 101)
        #expect(summary.motionTimeline.count == 5)
        #expect(summary.heartRateTimeline.count == 3)
    }

    @Test
    func reportsMissingIMUSequenceWithoutInventingSamples() throws {
        let url = try makeJournal(
            sampleCount: 201,
            hz: 50,
            missingSequence: 75
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try WatchSessionSummaryAnalyzer.summarizeJournal(
            at: url
        )

        #expect(summary.imuSampleCount == 200)
        #expect(summary.missingIMUSequences == 1)
        #expect(summary.maxIMUMilliseconds >= 39.9)
    }

    @Test
    func rejectsMixedSessionJournal() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let events = [
            SensorEnvelope(
                sessionID: "one",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 1,
                payload: [:]
            ),
            SensorEnvelope(
                sessionID: "two",
                deviceID: "apple-watch",
                stream: "/body/watch/imu",
                sequence: 0,
                deviceTimeNS: 2,
                payload: imuPayload(index: 0)
            ),
        ]
        try write(events, to: url)

        #expect(throws: WatchSessionSummaryAnalyzer.AnalysisError.self) {
            try WatchSessionSummaryAnalyzer.summarizeJournal(at: url)
        }
    }

    private func makeJournal(
        sampleCount: Int,
        hz: Double,
        missingSequence: Int?
    ) throws -> URL {
        let dtNS = UInt64(1_000_000_000 / hz)
        var events: [SensorEnvelope] = [
            SensorEnvelope(
                sessionID: "review-fixture",
                deviceID: "apple-watch",
                stream: "/meta/watch",
                sequence: 0,
                deviceTimeNS: 1,
                payload: [
                    "capture_origin": .string("Watch test"),
                    "model": .string("Apple Watch"),
                    "system_version": .string("26.6"),
                    "wrist_location": .string("left"),
                ]
            )
        ]

        for sequence in 0..<sampleCount {
            if sequence == missingSequence {
                continue
            }
            events.append(
                SensorEnvelope(
                    sessionID: "review-fixture",
                    deviceID: "apple-watch",
                    stream: "/body/watch/imu",
                    sequence: UInt64(sequence),
                    deviceTimeNS: UInt64(sequence) * dtNS,
                    payload: Self.imuPayload(index: sequence)
                )
            )
        }

        for sequence in 0..<3 {
            events.append(
                SensorEnvelope(
                    sessionID: "review-fixture",
                    deviceID: "apple-watch",
                    stream: "/body/watch/hr",
                    sequence: UInt64(sequence),
                    deviceTimeNS:
                        UInt64(sequence + 1) * 1_000_000_000,
                    payload: ["bpm": .number(Double(100 + sequence))]
                )
            )
        }

        let url = temporaryURL()
        try write(events, to: url)
        return url
    }

    private static func imuPayload(
        index: Int
    ) -> [String: JSONValue] {
        let standardGravity = 9.80665
        let pulse = index % 50 == 0 ? 1.5 : 0.05
        return [
            "ax": .number(pulse),
            "ay": .number(0),
            "az": .number(standardGravity),
            "gx": .number(Double(index % 7) * 0.05),
            "gy": .number(0.15),
            "gz": .number(0.08),
            "roll": .number(Double(index) * 0.001),
            "pitch": .number(Double(index) * 0.0005),
            "yaw": .number(Double(index) * 0.0015),
        ]
    }

    private func write(
        _ events: [SensorEnvelope],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "motionos-review-\(UUID().uuidString).jsonl"
            )
    }
}
