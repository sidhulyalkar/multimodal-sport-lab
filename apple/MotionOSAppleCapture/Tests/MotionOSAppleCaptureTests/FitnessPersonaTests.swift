import XCTest
@testable import MotionOSAppleCapture

final class FitnessPersonaTests: XCTestCase {
    func testCoverageTracksComparableRepeatedEvidenceWithoutScoringSkill() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let evidence = [
            session(
                id: "a",
                date: start,
                acceleration: 0.20,
                heartRate: 118
            ),
            session(
                id: "b",
                date: start.addingTimeInterval(86_400 * 7),
                acceleration: 0.18,
                heartRate: 116
            ),
            session(
                id: "c",
                date: start.addingTimeInterval(86_400 * 14),
                acceleration: 0.17,
                heartRate: 114
            ),
        ]

        let snapshot = FitnessPersonaEngine.build(
            evidence: evidence,
            generatedAt: start.addingTimeInterval(86_400 * 15)
        )

        XCTAssertEqual(snapshot.sourceSessionCount, 3)

        let movement = try XCTUnwrap(
            snapshot.state(for: .movement)
        )
        XCTAssertEqual(movement.coverage, .repeated)
        XCTAssertEqual(movement.evidenceSessionCount, 3)
        XCTAssertEqual(movement.baselines.count, 1)

        let baseline = try XCTUnwrap(movement.baselines.first)
        XCTAssertEqual(baseline.sampleCount, 3)
        XCTAssertEqual(baseline.median, 0.18, accuracy: 1e-9)
        XCTAssertEqual(baseline.latestValue, 0.17, accuracy: 1e-9)
        XCTAssertNotNil(baseline.trendPer30Days)

        let cardio = try XCTUnwrap(
            snapshot.state(for: .cardiovascularResponse)
        )
        XCTAssertEqual(cardio.coverage, .repeated)

        let power = try XCTUnwrap(
            snapshot.state(for: .power)
        )
        XCTAssertEqual(power.coverage, .none)
        XCTAssertTrue(power.baselines.isEmpty)
    }

    func testDifferentCaptureContextsDoNotCollapseIntoOneBaseline() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let a = session(
            id: "a",
            date: start,
            acceleration: 0.20,
            heartRate: nil,
            captureMode: "watch_phone"
        )
        let b = session(
            id: "b",
            date: start.addingTimeInterval(86_400),
            acceleration: 0.30,
            heartRate: nil,
            captureMode: "multiview"
        )

        let snapshot = FitnessPersonaEngine.build(
            evidence: [a, b],
            generatedAt: start.addingTimeInterval(100_000)
        )
        let movement = try XCTUnwrap(
            snapshot.state(for: .movement)
        )

        XCTAssertEqual(movement.evidenceSessionCount, 2)
        XCTAssertEqual(movement.baselines.count, 2)
        XCTAssertTrue(
            movement.baselines.allSatisfy {
                $0.sampleCount == 1
            }
        )
    }

    func testDuplicateSessionIDKeepsNewestEvidenceOnly() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let old = session(
            id: "same",
            date: start,
            acceleration: 0.9,
            heartRate: nil
        )
        let new = session(
            id: "same",
            date: start.addingTimeInterval(1),
            acceleration: 0.2,
            heartRate: nil
        )

        let snapshot = FitnessPersonaEngine.build(
            evidence: [old, new],
            generatedAt: start.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.sourceSessionCount, 1)
        let baseline = try XCTUnwrap(
            snapshot.state(for: .movement)?.baselines.first
        )
        XCTAssertEqual(baseline.latestValue, 0.2, accuracy: 1e-9)
    }

    func testAbortedAndNonFiniteEvidenceDoNotBecomePersonaEvidence() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let aborted = PersonaSessionEvidence(
            id: "aborted",
            sport: "indo_board",
            protocolID: "p",
            captureMode: "standard",
            observedAt: start,
            completed: false,
            sources: [.appleWatch],
            metrics: [
                PersonaMetricObservation(
                    dimension: .movement,
                    metricID: "metric",
                    label: "Metric",
                    unit: "u",
                    value: 1,
                    observedAt: start,
                    contextKey: "ctx",
                    provenance: .derived,
                    sourceSessionID: "aborted"
                )
            ]
        )
        let invalid = PersonaSessionEvidence(
            id: "invalid",
            sport: "indo_board",
            protocolID: "p",
            captureMode: "standard",
            observedAt: start,
            completed: true,
            sources: [.appleWatch],
            metrics: [
                PersonaMetricObservation(
                    dimension: .movement,
                    metricID: "metric",
                    label: "Metric",
                    unit: "u",
                    value: .nan,
                    observedAt: start,
                    contextKey: "ctx",
                    provenance: .derived,
                    sourceSessionID: "invalid"
                )
            ]
        )

        let snapshot = FitnessPersonaEngine.build(
            evidence: [aborted, invalid],
            generatedAt: start
        )

        XCTAssertEqual(snapshot.sourceSessionCount, 1)
        XCTAssertEqual(
            snapshot.state(for: .movement)?.coverage,
            .none
        )
    }

    func testBodyModelKeepsLatestObservationPerParameter() throws {
        let start = Date(timeIntervalSince1970: 5_000)
        let oldHeight = BodyParameterObservation(
            kind: .standingHeight,
            valueMeters: 1.70,
            observedAt: start,
            provenance: .userMeasurement,
            sourceID: "manual-old"
        )
        let newHeight = BodyParameterObservation(
            kind: .standingHeight,
            valueMeters: 1.71,
            observedAt: start.addingTimeInterval(100),
            provenance: .visionCalibration,
            sourceID: "vision-new",
            uncertaintyMeters: 0.01
        )
        let femur = BodyParameterObservation(
            kind: .leftFemurLength,
            valueMeters: 0.43,
            observedAt: start,
            provenance: .visionCalibration,
            sourceID: "vision-new"
        )

        let model = try PersonalBodyModelBuilder.build(
            versionID: "body-v1",
            calibratedAt: start.addingTimeInterval(100),
            observations: [oldHeight, newHeight, femur]
        )

        XCTAssertEqual(model.versionID, "body-v1")
        XCTAssertEqual(
            try XCTUnwrap(
                model.parameter(.standingHeight)?.valueMeters
            ),
            1.71,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(
                model.parameter(.leftFemurLength)?.valueMeters
            ),
            0.43,
            accuracy: 1e-9
        )
    }

    func testBodyModelRejectsInvalidGeometry() {
        let invalid = BodyParameterObservation(
            kind: .standingHeight,
            valueMeters: -1,
            observedAt: Date(),
            provenance: .userMeasurement,
            sourceID: "bad"
        )

        XCTAssertThrowsError(
            try PersonalBodyModelBuilder.build(
                versionID: "body-v1",
                calibratedAt: Date(),
                observations: [invalid]
            )
        )
    }

    private func session(
        id: String,
        date: Date,
        acceleration: Double,
        heartRate: Double?,
        captureMode: String = "watch_phone"
    ) -> PersonaSessionEvidence {
        let context = [
            "indo_board",
            "motionos.indo-board-product-session.v1",
            captureMode,
        ].joined(separator: "|")

        var metrics = [
            PersonaMetricObservation(
                dimension: .movement,
                metricID: "watch.user_acceleration_rms_g",
                label: "Watch acceleration RMS",
                unit: "g",
                value: acceleration,
                observedAt: date,
                contextKey: context,
                provenance: .derived,
                sourceSessionID: id
            )
        ]

        if let heartRate {
            metrics.append(
                PersonaMetricObservation(
                    dimension: .cardiovascularResponse,
                    metricID: "watch.mean_heart_rate_bpm",
                    label: "Mean heart rate",
                    unit: "bpm",
                    value: heartRate,
                    observedAt: date,
                    contextKey: context,
                    provenance: .derived,
                    sourceSessionID: id
                )
            )
        }

        return PersonaSessionEvidence(
            id: id,
            sport: "indo_board",
            protocolID: "motionos.indo-board-product-session.v1",
            captureMode: captureMode,
            observedAt: date,
            completed: true,
            sources: [.appleWatch],
            metrics: metrics
        )
    }
}
