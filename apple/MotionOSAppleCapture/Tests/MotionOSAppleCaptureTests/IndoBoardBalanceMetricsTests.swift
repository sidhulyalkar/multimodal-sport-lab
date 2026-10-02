import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardBalanceMetricsTests: XCTestCase {
    func testCenteredSamplesProduceHighCenterTime() {
        let accumulator = IndoBoardBalanceMetricAccumulator()

        for index in 0..<100 {
            accumulator.ingest(
                state(
                    sequence: index,
                    position: sin(Double(index) * 0.08) * 0.10,
                    confidence: 0.9
                ),
                elapsedSeconds: Double(index) * 0.1
            )
        }

        let metrics = accumulator.makeMetrics()

        XCTAssertNotNil(metrics)
        XCTAssertGreaterThan(
            metrics?.centerTimeFraction ?? 0,
            0.95
        )
        XCTAssertLessThan(
            metrics?.rollerExcursionP90 ?? 1,
            0.15
        )
        XCTAssertEqual(
            metrics?.edgeApproachCount,
            0
        )
    }

    func testExcursionAndReturnProducesRecoveryTiming() {
        let accumulator = IndoBoardBalanceMetricAccumulator()
        let positions: [Double] = [
            0.0, 0.10, 0.30, 0.58, 0.70,
            0.62, 0.48, 0.34, 0.24, 0.12,
        ]

        // Repeat the trajectory so we clear the minimum sample gate.
        for cycle in 0..<4 {
            for (offset, position) in positions.enumerated() {
                let index = cycle * positions.count + offset
                accumulator.ingest(
                    state(
                        sequence: index,
                        position: position,
                        confidence: 0.92
                    ),
                    elapsedSeconds: Double(index) * 0.1
                )
            }
        }

        let metrics = accumulator.makeMetrics()

        XCTAssertEqual(metrics?.recoveryCount, 4)
        XCTAssertEqual(
            metrics?.meanRecoveryTimeMS ?? 0,
            500,
            accuracy: 20
        )
        XCTAssertGreaterThan(
            metrics?.rollerExcursionP90 ?? 0,
            0.60
        )
    }

    func testEdgeApproachCountsTransitionsNotFrames() {
        let accumulator = IndoBoardBalanceMetricAccumulator()
        let positions: [Double] = [
            0, 0.4, 0.76, 0.82, 0.78, 0.4, 0.1,
            -0.4, -0.78, -0.84, -0.79, -0.3, 0,
        ]

        for cycle in 0..<3 {
            for (offset, position) in positions.enumerated() {
                let index = cycle * positions.count + offset
                accumulator.ingest(
                    state(
                        sequence: index,
                        position: position,
                        confidence: 0.88
                    ),
                    elapsedSeconds: Double(index) * 0.1
                )
            }
        }

        let metrics = accumulator.makeMetrics()

        XCTAssertEqual(metrics?.edgeApproachCount, 6)
    }

    func testLowConfidenceSamplesAreIgnored() {
        let accumulator = IndoBoardBalanceMetricAccumulator()

        for index in 0..<30 {
            accumulator.ingest(
                state(
                    sequence: index,
                    position: 0.9,
                    confidence: 0.2
                ),
                elapsedSeconds: Double(index) * 0.1
            )
        }

        XCTAssertNil(accumulator.makeMetrics())
    }

    private func state(
        sequence: Int,
        position: Double,
        confidence: Double
    ) -> IndoBoardBalanceState {
        IndoBoardBalanceState(
            sequence: UInt64(sequence),
            deviceTimeNS: UInt64(sequence) * 100_000_000,
            deckAngleImageRadians: 0,
            rollerAlongDeck: position,
            rollerPerpendicularOffsetDeckLengths: 0,
            centerProximity: max(0, 1 - abs(position)),
            confidence: confidence,
            provenance: .modelEstimated
        )
    }
}
