import XCTest
@testable import MotionOSAppleCapture

final class DualViewPlaybackSyncTests: XCTestCase {
    func testOverlapWindowClipsToSharedReferenceInterval() throws {
        let window = try XCTUnwrap(
            DualViewPlaybackSyncPolicy
                .referenceOverlapWindow(
                    referenceDurationSeconds: 120,
                    sourceDurationNS:
                        130_000_000_000,
                    slope: 1,
                    interceptNS:
                        -5_000_000_000
                )
        )

        XCTAssertEqual(
            window.startSeconds,
            0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            window.endSeconds,
            120,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            window.durationSeconds,
            120,
            accuracy: 1e-12
        )
    }

    func testOverlapWindowRejectsNonoverlappingSource() {
        XCTAssertNil(
            DualViewPlaybackSyncPolicy
                .referenceOverlapWindow(
                    referenceDurationSeconds: 60,
                    sourceDurationNS:
                        5_000_000_000,
                    slope: 1,
                    interceptNS:
                        70_000_000_000
                )
        )
    }

    func testReferenceDriftUsesClockSlopeAndIntercept() throws {
        let drift = try XCTUnwrap(
            DualViewPlaybackSyncPolicy
                .referenceDriftMS(
                    referencePTSNS:
                        10_000_000_000,
                    observedSourcePTSNS:
                        9_900_000_000,
                    slope: 1.002,
                    interceptNS:
                        100_000_000
                )
        )

        XCTAssertEqual(
            drift,
            19.8,
            accuracy: 1e-9
        )
    }

    func testMappedReferenceDecisionUsesReferenceClockThreshold() throws {
        let decision = try XCTUnwrap(
            DualViewPlaybackSyncPolicy
                .evaluateMappedReference(
                    referencePTSNS:
                        10_000_000_000,
                    observedSourcePTSNS:
                        9_900_000_000,
                    slope: 1.002,
                    interceptNS:
                        100_000_000,
                    correctionThresholdMS: 15,
                    correctionAllowed: true
                )
        )

        XCTAssertEqual(
            decision.driftMS,
            19.8,
            accuracy: 1e-9
        )
        XCTAssertTrue(
            decision.shouldCorrect
        )
    }

    func testLateStartingSourceProducesClippedOverlap() throws {
        let window = try XCTUnwrap(
            DualViewPlaybackSyncPolicy
                .referenceOverlapWindow(
                    referenceDurationSeconds: 60,
                    sourceDurationNS:
                        40_000_000_000,
                    slope: 1,
                    interceptNS:
                        10_000_000_000
                )
        )

        XCTAssertEqual(
            window.startSeconds,
            10,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            window.endSeconds,
            50,
            accuracy: 1e-12
        )
    }

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
