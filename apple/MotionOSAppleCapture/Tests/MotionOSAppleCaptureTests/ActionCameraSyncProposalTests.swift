import XCTest
@testable import MotionOSAppleCapture

final class ActionCameraSyncProposalTests: XCTestCase {
    func testFindsThreeGesturePeaksWithoutAbsoluteOffset() throws {
        let references = [
            SyncReferenceGesture(
                label: "start",
                referenceTimeNS: 10_000_000_000,
                cueTimeNS: 9_800_000_000,
                energy: 1.2,
                confidence: 0.95
            ),
            SyncReferenceGesture(
                label: "middle",
                referenceTimeNS: 85_000_000_000,
                cueTimeNS: 84_700_000_000,
                energy: 1.4,
                confidence: 0.96
            ),
            SyncReferenceGesture(
                label: "end",
                referenceTimeNS: 114_000_000_000,
                cueTimeNS: 113_700_000_000,
                energy: 1.3,
                confidence: 0.94
            ),
        ]

        // Action camera started 7 s earlier than the reference timeline.
        // The actual gesture peaks therefore land at 17, 92 and 121 s.
        let gestureTimes: Set<UInt64> = [
            17_000_000_000,
            92_000_000_000,
            121_000_000_000,
        ]
        var trace: [MotionEnergySample] = []
        for step in 0...650 {
            let time = UInt64(step) * 200_000_000
            let base = 0.05
            let energy: Double
            if gestureTimes.contains(time) {
                energy = 1.8
            } else if step == 150 || step == 350 || step == 600 {
                energy = 0.55
            } else {
                energy = base
            }
            trace.append(
                MotionEnergySample(
                    timeNS: time,
                    energy: energy,
                    confidence: 0.92
                )
            )
        }

        let proposal = try XCTUnwrap(
            ActionCameraSyncMatcher.propose(
                referenceGestures: references,
                externalTrace: trace
            )
        )

        XCTAssertEqual(
            proposal.anchors.map(\.label),
            ["start", "middle", "end"]
        )
        XCTAssertEqual(
            proposal.anchors.map(\.externalPTSNS),
            [
                17_000_000_000,
                92_000_000_000,
                121_000_000_000,
            ]
        )
        XCTAssertEqual(
            proposal.affineSlope,
            1.0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            proposal.affineInterceptNS,
            -7_000_000_000,
            accuracy: 1
        )
        XCTAssertEqual(
            proposal.middleResidualNS,
            0,
            accuracy: 1
        )
        XCTAssertGreaterThan(proposal.confidence, 0.8)
    }

    func testRejectsTriplesWithImplausibleClockScale() {
        let references = referenceGestures
        let trace = [
            MotionEnergySample(
                timeNS: 1_000_000_000,
                energy: 1,
                confidence: 1
            ),
            MotionEnergySample(
                timeNS: 20_000_000_000,
                energy: 1,
                confidence: 1
            ),
            MotionEnergySample(
                timeNS: 40_000_000_000,
                energy: 1,
                confidence: 1
            ),
        ]

        XCTAssertNil(
            ActionCameraSyncMatcher.propose(
                referenceGestures: references,
                externalTrace: trace
            )
        )
    }

    func testStrongestGestureUsesCueWindowAndConfidence() throws {
        let trace = [
            MotionEnergySample(
                timeNS: 9_700_000_000,
                energy: 0.4,
                confidence: 0.9
            ),
            MotionEnergySample(
                timeNS: 10_300_000_000,
                energy: 0.8,
                confidence: 0.8
            ),
            MotionEnergySample(
                timeNS: 10_800_000_000,
                energy: 0.75,
                confidence: 1.0
            ),
            MotionEnergySample(
                timeNS: 13_000_000_000,
                energy: 5,
                confidence: 1
            ),
        ]

        let peak = try XCTUnwrap(
            ActionCameraSyncMatcher.strongestGesture(
                in: trace,
                around: 10_000_000_000
            )
        )

        XCTAssertEqual(
            peak.timeNS,
            10_800_000_000
        )
    }

    func testRequiresStartMiddleEndReferences() {
        XCTAssertNil(
            ActionCameraSyncMatcher.propose(
                referenceGestures: Array(
                    referenceGestures.prefix(2)
                ),
                externalTrace: []
            )
        )
    }

    private var referenceGestures: [SyncReferenceGesture] {
        [
            .init(
                label: "start",
                referenceTimeNS: 10_000_000_000,
                energy: 1,
                confidence: 1
            ),
            .init(
                label: "middle",
                referenceTimeNS: 85_000_000_000,
                energy: 1,
                confidence: 1
            ),
            .init(
                label: "end",
                referenceTimeNS: 114_000_000_000,
                energy: 1,
                confidence: 1
            ),
        ]
    }
}
