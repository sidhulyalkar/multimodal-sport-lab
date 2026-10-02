import XCTest
@testable import MotionOSAppleCapture

final class PlayerCardTests: XCTestCase {
    func testPlayerCardIncludesOnlyShareSafeMovementDimensions() {
        let now = Date(timeIntervalSince1970: 10_000)

        let persona = FitnessPersonaSnapshot(
            generatedAt: now,
            sourceSessionCount: 7,
            bodyModelVersion: "body-v1",
            dimensions: [
                state(
                    .movement,
                    coverage: .longitudinal,
                    baseline: baseline(
                        dimension: .movement,
                        metricID: "movement.accel",
                        label: "Movement trace",
                        value: 0.42,
                        unit: "g",
                        date: now
                    )
                ),
                state(
                    .cardiovascularResponse,
                    coverage: .longitudinal,
                    baseline: baseline(
                        dimension: .cardiovascularResponse,
                        metricID: "cardio.hr",
                        label: "Heart rate",
                        value: 155,
                        unit: "bpm",
                        date: now
                    )
                ),
                state(
                    .power,
                    coverage: .repeated,
                    baseline: baseline(
                        dimension: .power,
                        metricID: "power.root.speed",
                        label: "Root speed proxy",
                        value: 1.8,
                        unit: "m/s",
                        date: now
                    )
                ),
                state(
                    .mobility,
                    coverage: .singleSession,
                    baseline: baseline(
                        dimension: .mobility,
                        metricID: "mobility.shoulder",
                        label: "Shoulder envelope",
                        value: 142,
                        unit: "deg",
                        date: now
                    )
                ),
                state(
                    .recovery,
                    coverage: .repeated,
                    baseline: baseline(
                        dimension: .recovery,
                        metricID: "recovery.hrv",
                        label: "HRV",
                        value: 48,
                        unit: "ms",
                        date: now
                    )
                ),
                state(
                    .body,
                    coverage: .repeated,
                    baseline: baseline(
                        dimension: .body,
                        metricID: "body.mass",
                        label: "Body mass",
                        value: 70,
                        unit: "kg",
                        date: now
                    )
                ),
            ]
        )

        let card = PlayerCardEngine.build(
            from: persona,
            generatedAt: now
        )

        XCTAssertEqual(
            card.dimensions.map { $0.dimension },
            [.movement, .power, .mobility]
        )
        XCTAssertEqual(
            card.highlights.map { $0.dimension },
            [.movement, .power, .mobility]
        )
        XCTAssertFalse(
            card.highlights.contains {
                $0.dimension == .cardiovascularResponse
                    || $0.dimension == .recovery
                    || $0.dimension == .body
            }
        )
        XCTAssertEqual(card.shareableEvidenceDepth, 3)
        XCTAssertTrue(card.bodyModelCalibrated)
        XCTAssertTrue(
            card.privacyBoundary.contains("excludes HealthKit values")
        )
    }

    func testLatestBaselineWinsWithinShareableDimension() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        let movementState = FitnessPersonaDimensionState(
            dimension: .movement,
            coverage: .repeated,
            evidenceSessionCount: 2,
            latestObservedAt: new,
            sourceKinds: [.appleWatch],
            baselines: [
                baseline(
                    dimension: .movement,
                    metricID: "old",
                    label: "Old",
                    value: 1,
                    unit: "u",
                    date: old
                ),
                baseline(
                    dimension: .movement,
                    metricID: "new",
                    label: "New",
                    value: 2,
                    unit: "u",
                    date: new
                ),
            ]
        )

        let persona = FitnessPersonaSnapshot(
            generatedAt: new,
            sourceSessionCount: 2,
            bodyModelVersion: nil,
            dimensions: [
                movementState,
                emptyState(.cardiovascularResponse),
                emptyState(.power),
                emptyState(.mobility),
                emptyState(.recovery),
                emptyState(.body),
            ]
        )

        let card = PlayerCardEngine.build(
            from: persona,
            generatedAt: new
        )

        let highlight = try XCTUnwrap(
            card.highlights.first
        )
        XCTAssertEqual(highlight.metricID, "new")
        XCTAssertEqual(highlight.value, 2)
        XCTAssertFalse(card.bodyModelCalibrated)
    }

    func testMissingShareableDimensionRemainsExplicitlyUnmeasured() {
        let persona = FitnessPersonaSnapshot(
            generatedAt: Date(),
            sourceSessionCount: 0,
            bodyModelVersion: nil,
            dimensions: FitnessPersonaDimension.allCases.map {
                emptyState($0)
            }
        )

        let card = PlayerCardEngine.build(from: persona)

        XCTAssertEqual(card.dimensions.count, 3)
        XCTAssertTrue(
            card.dimensions.allSatisfy {
                $0.coverage == .none
                    && $0.evidenceSessionCount == 0
            }
        )
        XCTAssertTrue(card.highlights.isEmpty)
    }

    func testPlayerCardJSONRoundTrip() throws {
        let snapshot = PlayerCardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_234),
            shareableEvidenceDepth: 4,
            bodyModelCalibrated: true,
            dimensions: [
                .init(
                    dimension: .movement,
                    coverage: .repeated,
                    evidenceSessionCount: 3,
                    latestObservedAt:
                        Date(timeIntervalSince1970: 1_200)
                )
            ],
            highlights: [
                .init(
                    dimension: .movement,
                    metricID: "m",
                    label: "Movement",
                    unit: "u",
                    value: 1.2,
                    observedAt:
                        Date(timeIntervalSince1970: 1_200),
                    sampleCount: 3
                )
            ]
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "player-card-" + UUID().uuidString + ".json"
            )
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try PlayerCardStore.write(
            snapshot,
            to: url
        )
        let loaded = try PlayerCardStore.load(
            from: url
        )
        XCTAssertEqual(loaded, snapshot)
    }

    private func state(
        _ dimension: FitnessPersonaDimension,
        coverage: PersonaEvidenceCoverage,
        baseline: PersonaMetricBaseline
    ) -> FitnessPersonaDimensionState {
        FitnessPersonaDimensionState(
            dimension: dimension,
            coverage: coverage,
            evidenceSessionCount: baseline.sampleCount,
            latestObservedAt: baseline.latestObservedAt,
            sourceKinds: [.iPhoneVision],
            baselines: [baseline]
        )
    }

    private func emptyState(
        _ dimension: FitnessPersonaDimension
    ) -> FitnessPersonaDimensionState {
        FitnessPersonaDimensionState(
            dimension: dimension,
            coverage: .none,
            evidenceSessionCount: 0,
            latestObservedAt: nil,
            sourceKinds: [],
            baselines: []
        )
    }

    private func baseline(
        dimension: FitnessPersonaDimension,
        metricID: String,
        label: String,
        value: Double,
        unit: String,
        date: Date
    ) -> PersonaMetricBaseline {
        PersonaMetricBaseline(
            metricID: metricID,
            label: label,
            unit: unit,
            dimension: dimension,
            contextKey: "fixture",
            sampleCount: 3,
            median: value,
            medianAbsoluteDeviation: 0.1,
            latestValue: value,
            latestObservedAt: date,
            latestDeltaFromMedian: 0,
            trendPer30Days: nil,
            provenance: [.derived]
        )
    }
}
