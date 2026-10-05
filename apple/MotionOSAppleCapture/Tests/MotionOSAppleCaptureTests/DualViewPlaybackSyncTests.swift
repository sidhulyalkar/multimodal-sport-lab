import XCTest
@testable import MotionOSAppleCapture

final class DualViewPlaybackSyncTests: XCTestCase {
    func testPositiveDriftPastThresholdCorrects() {
        let decision =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS:
                    10_000_000_000,
                observedSourcePTSNS:
                    10_120_000_000,
                correctionThresholdMS: 90,
                correctionAllowed: true
            )

        XCTAssertEqual(
            decision.driftMS,
            120,
            accuracy: 1e-12
        )
        XCTAssertTrue(
            decision.shouldCorrect
        )
    }

    func testNegativeDriftPreservesSign() {
        let decision =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS:
                    10_000_000_000,
                observedSourcePTSNS:
                    9_875_000_000,
                correctionThresholdMS: 90,
                correctionAllowed: true
            )

        XCTAssertEqual(
            decision.driftMS,
            -125,
            accuracy: 1e-12
        )
        XCTAssertTrue(
            decision.shouldCorrect
        )
    }

    func testDriftInsideThresholdDoesNotSeek() {
        let decision =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS:
                    10_000_000_000,
                observedSourcePTSNS:
                    10_089_000_000,
                correctionThresholdMS: 90,
                correctionAllowed: true
            )

        XCTAssertFalse(
            decision.shouldCorrect
        )
    }

    func testCooldownCanSuppressOtherwiseNeededCorrection() {
        let decision =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS:
                    10_000_000_000,
                observedSourcePTSNS:
                    10_400_000_000,
                correctionThresholdMS: 90,
                correctionAllowed: false
            )

        XCTAssertEqual(
            decision.driftMS,
            400,
            accuracy: 1e-12
        )
        XCTAssertFalse(
            decision.shouldCorrect
        )
    }

    func testZeroThresholdStillRequiresNonzeroDrift() {
        let exact =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS: 42,
                observedSourcePTSNS: 42,
                correctionThresholdMS: 0,
                correctionAllowed: true
            )
        let late =
            DualViewPlaybackSyncPolicy.evaluate(
                expectedSourcePTSNS: 42,
                observedSourcePTSNS:
                    1_000_042,
                correctionThresholdMS: -1,
                correctionAllowed: true
            )

        XCTAssertFalse(
            exact.shouldCorrect
        )
        XCTAssertTrue(
            late.shouldCorrect
        )
    }
}
