import XCTest
@testable import MotionOSAppleCapture

final class PersonaReliabilityTests: XCTestCase {
    func testRepeatedComparableEvidenceProducesRobustSpread() throws {
        let day = Date(
            timeIntervalSince1970: 1_000_000
        )
        let evidence = [
            session(
                id: "a",
                date: day,
                value: 10
            ),
            session(
                id: "b",
                date: day.addingTimeInterval(60),
                value: 12
            ),
            session(
                id: "c",
                date: day.addingTimeInterval(2 * 86_400),
                value: 14
            ),
        ]

        let snapshot =
            PersonaReliabilityEngine.build(
                evidence: evidence,
                generatedAt: day
            )

        let series = try XCTUnwrap(
            snapshot.series.first
        )
        XCTAssertEqual(
            series.sourceSessionCount,
            3
        )
        XCTAssertEqual(
            series.sampleCount,
            3
        )
        XCTAssertEqual(
            series.median,
            12,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            series.medianAbsoluteDeviation,
            2,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            series.latestDeltaFromMedian,
            2,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            series.maximumSameDayRepeatCount,
            2
        )
        XCTAssertEqual(
            series.spanDays,
            2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(
                series.relativeMADFraction
            ),
            2.0 / 12.0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            series.coverage,
            .repeated
        )
    }

    func testDifferentContextsAndUnitsDoNotMerge() {
        let date = Date(
            timeIntervalSince1970: 2_000_000
        )

        let evidence = [
            session(
                id: "a",
                date: date,
                value: 1,
                context: "protocol-a",
                unit: "m/s"
            ),
            session(
                id: "b",
                date: date,
                value: 2,
                context: "protocol-b",
                unit: "m/s"
            ),
            session(
                id: "c",
                date: date,
                value: 3,
                context: "protocol-a",
                unit: "cm/s"
            ),
        ]

        let snapshot =
            PersonaReliabilityEngine.build(
                evidence: evidence
            )

        XCTAssertEqual(
            snapshot.series.count,
            3
        )
        XCTAssertTrue(
            snapshot.series.allSatisfy {
                $0.sourceSessionCount == 1
            }
        )
    }

    func testIncompleteAndOlderDuplicateEvidenceAreExcluded() throws {
        let old = Date(
            timeIntervalSince1970: 3_000_000
        )
        let new = old.addingTimeInterval(
            100
        )

        let evidence = [
            session(
                id: "same",
                date: old,
                value: 99
            ),
            session(
                id: "same",
                date: new,
                value: 5
            ),
            session(
                id: "incomplete",
                date: new,
                value: 123,
                completed: false
            ),
        ]

        let snapshot =
            PersonaReliabilityEngine.build(
                evidence: evidence
            )
        let series = try XCTUnwrap(
            snapshot.series.first
        )

        XCTAssertEqual(
            series.sourceSessionCount,
            1
        )
        XCTAssertEqual(
            series.median,
            5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            snapshot.contributingSessionCount,
            1
        )
    }

    func testZeroCenteredMetricDoesNotInventRelativeSpread() throws {
        let now = Date()
        let evidence = [
            session(
                id: "a",
                date: now,
                value: -1
            ),
            session(
                id: "b",
                date: now.addingTimeInterval(1),
                value: 0
            ),
            session(
                id: "c",
                date: now.addingTimeInterval(2),
                value: 1
            ),
        ]

        let snapshot =
            PersonaReliabilityEngine.build(
                evidence: evidence
            )
        let series = try XCTUnwrap(
            snapshot.series.first
        )

        XCTAssertEqual(
            series.median,
            0,
            accuracy: 1e-12
        )
        XCTAssertNil(
            series.relativeMADFraction
        )
    }

    func testSnapshotRoundTrip() throws {
        let snapshot =
            PersonaReliabilitySnapshot(
                generatedAt: Date(
                    timeIntervalSince1970:
                        5_000
                ),
                contributingSessionCount: 3,
                series: []
            )

        let url =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "reliability-"
                        + UUID().uuidString
                        + ".json"
                )
        defer {
            try? FileManager.default
                .removeItem(at: url)
        }

        try PersonaReliabilityStore.write(
            snapshot,
            to: url
        )
        let loaded =
            try PersonaReliabilityStore.load(
                from: url
            )

        XCTAssertEqual(
            loaded,
            snapshot
        )
    }

    private func session(
        id: String,
        date: Date,
        value: Double,
        context: String = "power|v1",
        unit: String = "m/s",
        completed: Bool = true
    ) -> PersonaSessionEvidence {
        let metric =
            PersonaMetricObservation(
                dimension: .power,
                metricID:
                    "vision.root_vertical_speed_proxy",
                label:
                    "Root vertical speed proxy",
                unit: unit,
                value: value,
                observedAt: date,
                contextKey: context,
                provenance: .derived,
                sourceSessionID: id
            )

        return PersonaSessionEvidence(
            id: id,
            sport: "power_challenge",
            protocolID: "power-v1",
            captureMode:
                "iphone_vision_fixed_camera",
            observedAt: date,
            completed: completed,
            sources: [.iPhoneVision],
            metrics: [metric]
        )
    }
}
