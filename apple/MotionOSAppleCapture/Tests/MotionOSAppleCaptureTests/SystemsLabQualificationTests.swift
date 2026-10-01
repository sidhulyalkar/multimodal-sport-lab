import XCTest
@testable import MotionOSAppleCapture

final class SystemsLabQualificationTests: XCTestCase {
    func testTracksOneSessionAndTransferReceipt() throws {
        var tracker = SystemsLabQualificationTracker()
        let start = Date(timeIntervalSince1970: 1_000)

        tracker.observePresence(
            sessionID: "session-a",
            captureState: "running",
            watchBatteryFraction: 0.80,
            phoneBatteryFraction: 0.70,
            receivedAt: start
        )

        tracker.ingest(
            snapshot(
                sessionID: "session-a",
                sequence: 0,
                imuCount: 100,
                effectiveHz: 50,
                maxGapMS: 20,
                nonMonotonic: 0,
                battery: 0.80
            ),
            receivedAt: start.addingTimeInterval(0.25),
            phoneBatteryFraction: 0.70
        )
        tracker.ingest(
            snapshot(
                sessionID: "session-a",
                sequence: 1,
                imuCount: 113,
                effectiveHz: 49.8,
                maxGapMS: 24,
                nonMonotonic: 0,
                battery: 0.79
            ),
            receivedAt: start.addingTimeInterval(0.50),
            phoneBatteryFraction: 0.69
        )

        tracker.observePresence(
            sessionID: "session-a",
            captureState: "transferQueued",
            watchBatteryFraction: 0.79,
            phoneBatteryFraction: 0.69,
            receivedAt: start.addingTimeInterval(10)
        )

        tracker.markJournalReceived(
            sessionID: "session-a",
            receivedAt: start.addingTimeInterval(12),
            byteCount: 42_000,
            sha256: "abc123"
        )

        let report = try XCTUnwrap(tracker.latestCompleted)
        XCTAssertEqual(report.sessionID, "session-a")
        XCTAssertEqual(report.telemetryPacketsReceived, 2)
        XCTAssertEqual(report.telemetrySequenceGaps, 0)
        XCTAssertEqual(report.imuSamplesObserved, 13)
        XCTAssertEqual(report.maximumIMUGapMS, 24)
        XCTAssertEqual(report.durationSeconds, 10)
        XCTAssertEqual(report.transferLatencySeconds, 2)
        XCTAssertEqual(report.journalByteCount, 42_000)
        XCTAssertEqual(report.journalSHA256, "abc123")
        XCTAssertEqual(
            try XCTUnwrap(report.watchBatteryDropFraction),
            0.01,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(report.phoneBatteryDropFraction),
            0.01,
            accuracy: 1e-9
        )
        XCTAssertNil(report.observedWatchBatteryDropPerHour)
    }

    func testCountsPreviewSequenceGapsWithoutCallingThemNetworkLoss() throws {
        var tracker = SystemsLabQualificationTracker()
        let start = Date(timeIntervalSince1970: 2_000)

        tracker.ingest(
            snapshot(sessionID: "s", sequence: 10, imuCount: 10),
            receivedAt: start,
            phoneBatteryFraction: nil
        )
        tracker.ingest(
            snapshot(sessionID: "s", sequence: 13, imuCount: 20),
            receivedAt: start.addingTimeInterval(0.75),
            phoneBatteryFraction: nil
        )

        let report = try XCTUnwrap(tracker.current)
        XCTAssertEqual(report.telemetryPacketsReceived, 2)
        XCTAssertEqual(report.telemetrySequenceGaps, 2)
        XCTAssertNotNil(report.previewCoverageFraction)
    }

    func testDuplicateAndOutOfOrderPacketsDoNotAdvanceMeasurements() throws {
        var tracker = SystemsLabQualificationTracker()
        let start = Date(timeIntervalSince1970: 3_000)

        tracker.ingest(
            snapshot(sessionID: "s", sequence: 4, imuCount: 100),
            receivedAt: start,
            phoneBatteryFraction: nil
        )
        tracker.ingest(
            snapshot(sessionID: "s", sequence: 4, imuCount: 999),
            receivedAt: start.addingTimeInterval(0.1),
            phoneBatteryFraction: nil
        )
        tracker.ingest(
            snapshot(sessionID: "s", sequence: 3, imuCount: 999),
            receivedAt: start.addingTimeInterval(0.2),
            phoneBatteryFraction: nil
        )

        let report = try XCTUnwrap(tracker.current)
        XCTAssertEqual(report.telemetryPacketsReceived, 1)
        XCTAssertEqual(report.telemetryDuplicates, 1)
        XCTAssertEqual(report.telemetryOutOfOrder, 1)
        XCTAssertEqual(report.lastIMUSampleCount, 100)
    }

    func testNewSessionResetsSequenceAndRateAccumulator() throws {
        var tracker = SystemsLabQualificationTracker()
        let start = Date(timeIntervalSince1970: 4_000)

        tracker.ingest(
            snapshot(
                sessionID: "first",
                sequence: 30,
                imuCount: 100,
                effectiveHz: 45
            ),
            receivedAt: start,
            phoneBatteryFraction: nil
        )
        tracker.observePresence(
            sessionID: "first",
            captureState: "transferred",
            watchBatteryFraction: nil,
            phoneBatteryFraction: nil,
            receivedAt: start.addingTimeInterval(5)
        )
        tracker.ingest(
            snapshot(
                sessionID: "second",
                sequence: 0,
                imuCount: 1,
                effectiveHz: 50
            ),
            receivedAt: start.addingTimeInterval(6),
            phoneBatteryFraction: nil
        )

        XCTAssertEqual(tracker.latestCompleted?.sessionID, "first")
        XCTAssertEqual(tracker.current?.sessionID, "second")
        XCTAssertEqual(tracker.current?.telemetrySequenceGaps, 0)
        XCTAssertEqual(tracker.current?.meanEffectiveIMUHz, 50)
    }

    func testBatterySlopeRequiresTenMinutes() throws {
        var tracker = SystemsLabQualificationTracker()
        let start = Date(timeIntervalSince1970: 5_000)

        tracker.observePresence(
            sessionID: "long",
            captureState: "running",
            watchBatteryFraction: 0.90,
            phoneBatteryFraction: nil,
            receivedAt: start
        )
        tracker.observePresence(
            sessionID: "long",
            captureState: "transferred",
            watchBatteryFraction: 0.85,
            phoneBatteryFraction: nil,
            receivedAt: start.addingTimeInterval(1_800)
        )

        let report = try XCTUnwrap(tracker.latestCompleted)
        XCTAssertEqual(
            try XCTUnwrap(report.observedWatchBatteryDropPerHour),
            0.10,
            accuracy: 1e-9
        )
    }

    private func snapshot(
        sessionID: String,
        sequence: UInt64,
        imuCount: UInt64,
        effectiveHz: Double? = 50,
        maxGapMS: Double = 20,
        nonMonotonic: UInt64 = 0,
        battery: Double? = nil
    ) -> LiveTelemetrySnapshot {
        LiveTelemetrySnapshot(
            sessionID: sessionID,
            sequence: sequence,
            sourceMonotonicNS: sequence * 250_000_000,
            sourceSentAt: Date(timeIntervalSince1970: 10_000 + Double(sequence)),
            activity: .recording,
            elapsedSeconds: Double(sequence) * 0.25,
            imuSampleCount: imuCount,
            effectiveIMUHz: effectiveHz,
            recentMedianIMUHz: effectiveHz,
            maxIMUGapMS: maxGapMS,
            nonMonotonicIMUCount: nonMonotonic,
            motion: nil,
            heartRateBPM: nil,
            watchBatteryFraction: battery
        )
    }
}
