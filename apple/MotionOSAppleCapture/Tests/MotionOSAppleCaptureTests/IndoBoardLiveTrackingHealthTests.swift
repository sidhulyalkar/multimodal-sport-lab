import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardLiveTrackingHealthTests: XCTestCase {
    func testStableWindowRequiresSustainedCoverage() {
        let window = IndoBoardLiveTrackingWindow(
            capacity: 10
        )

        var health = IndoBoardLiveTrackingHealth.empty
        for index in 0..<10 {
            health = window.ingest(
                index < 7
                    ? state(confidence: 0.90)
                    : nil
            )
        }

        XCTAssertEqual(health.sampleCount, 10)
        XCTAssertEqual(health.trackedSampleCount, 7)
        XCTAssertEqual(
            health.coverageFraction,
            0.70,
            accuracy: 0.001
        )
        XCTAssertTrue(health.isStable)
    }

    func testOneLuckyFrameDoesNotMarkTrackingStable() {
        let window = IndoBoardLiveTrackingWindow(
            capacity: 10
        )

        var health = IndoBoardLiveTrackingHealth.empty
        for index in 0..<10 {
            health = window.ingest(
                index == 9
                    ? state(confidence: 0.95)
                    : nil
            )
        }

        XCTAssertEqual(health.trackedSampleCount, 1)
        XCTAssertFalse(health.isStable)
    }

    func testLowConfidenceTrackingDoesNotQualify() {
        let window = IndoBoardLiveTrackingWindow(
            capacity: 10
        )

        var health = IndoBoardLiveTrackingHealth.empty
        for _ in 0..<10 {
            health = window.ingest(
                state(confidence: 0.40)
            )
        }

        XCTAssertEqual(
            health.coverageFraction,
            1,
            accuracy: 0.001
        )
        XCTAssertFalse(health.isStable)
    }

    func testWindowRecoversAfterEarlyDropout() {
        let window = IndoBoardLiveTrackingWindow(
            capacity: 10
        )

        for _ in 0..<6 {
            _ = window.ingest(nil)
        }
        for _ in 0..<10 {
            _ = window.ingest(
                state(confidence: 0.90)
            )
        }

        let health = window.makeHealth()

        XCTAssertEqual(health.sampleCount, 10)
        XCTAssertEqual(health.trackedSampleCount, 10)
        XCTAssertTrue(health.isStable)
    }

    private func state(
        confidence: Double
    ) -> IndoBoardBalanceState {
        IndoBoardBalanceState(
            sequence: 1,
            deviceTimeNS: 1,
            deckAngleImageRadians: 0,
            rollerAlongDeck: 0,
            rollerPerpendicularOffsetDeckLengths: 0,
            centerProximity: 1,
            confidence: confidence,
            provenance: .fiducialMeasured
        )
    }
}
