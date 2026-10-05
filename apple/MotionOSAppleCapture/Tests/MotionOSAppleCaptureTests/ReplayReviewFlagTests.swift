import XCTest
@testable import MotionOSAppleCapture

final class ReplayReviewFlagTests:
    XCTestCase {
    func testFlagNormalizesNoteAndBindings() {
        let flag = ReplayReviewFlagV1(
            id: "flag-1",
            runID: "run-1",
            recordedAtUTC:
                "2026-10-05T00:00:00Z",
            referenceTimeNS:
                12_500_000_000,
            action4VideoPTSNS:
                13_000_000_000,
            scope: .action4Pose,
            verdict: .wrong,
            note: "  knee joint jumped  ",
            iPhonePoseAvailable: true,
            action4PoseAvailable: true,
            equipmentAvailable: false,
            observedPlaybackDriftMS:
                .infinity,
            artifactBindings: [
                ReplayReviewArtifactBindingV1(
                    role: "video_alignment",
                    sha256: "bbb"
                ),
                ReplayReviewArtifactBindingV1(
                    role: "action4_pose_track",
                    sha256: "aaa"
                ),
            ]
        )

        XCTAssertEqual(
            flag.note,
            "knee joint jumped"
        )
        XCTAssertNil(
            flag.observedPlaybackDriftMS
        )
        XCTAssertEqual(
            flag.artifactBindings
                .map(\.role),
            [
                "action4_pose_track",
                "video_alignment",
            ]
        )
    }

    func testLedgerOrdersByReferenceTime() throws {
        let late = ReplayReviewFlagV1(
            id: "late",
            runID: "run-1",
            recordedAtUTC:
                "2026-10-05T00:00:02Z",
            referenceTimeNS:
                20_000_000_000,
            action4VideoPTSNS: nil,
            scope: .behavior,
            iPhonePoseAvailable: true,
            action4PoseAvailable: false,
            equipmentAvailable: false,
            observedPlaybackDriftMS: nil,
            artifactBindings: []
        )
        let early = ReplayReviewFlagV1(
            id: "early",
            runID: "run-1",
            recordedAtUTC:
                "2026-10-05T00:00:01Z",
            referenceTimeNS:
                5_000_000_000,
            action4VideoPTSNS: nil,
            scope: .behavior,
            iPhonePoseAvailable: true,
            action4PoseAvailable: false,
            equipmentAvailable: false,
            observedPlaybackDriftMS: nil,
            artifactBindings: []
        )

        let ledger =
            try ReplayReviewLedgerV1(
                runID: "run-1"
            )
            .appending(late)
            .appending(early)

        XCTAssertEqual(
            ledger.flags.map(\.id),
            ["early", "late"]
        )
    }

    func testLedgerRejectsCrossRunFlag() {
        let flag = ReplayReviewFlagV1(
            id: "flag-1",
            runID: "run-2",
            referenceTimeNS: 0,
            action4VideoPTSNS: nil,
            scope: .timing,
            iPhonePoseAvailable: false,
            action4PoseAvailable: false,
            equipmentAvailable: false,
            observedPlaybackDriftMS: nil,
            artifactBindings: []
        )

        XCTAssertThrowsError(
            try ReplayReviewLedgerV1(
                runID: "run-1"
            )
            .appending(flag)
        ) { error in
            XCTAssertEqual(
                error as? ReplayReviewLedgerError,
                .runMismatch
            )
        }
    }

    func testRoundTripPreservesEvidenceWindow()
        throws {
        let original =
            ReplayReviewLedgerV1(
                runID: "run-1",
                flags: [
                    ReplayReviewFlagV1(
                        id: "flag-1",
                        runID: "run-1",
                        recordedAtUTC:
                            "2026-10-05T00:00:00Z",
                        referenceTimeNS:
                            42_000_000_000,
                        action4VideoPTSNS:
                            41_950_000_000,
                        windowBeforeNS:
                            2_000_000_000,
                        windowAfterNS:
                            3_000_000_000,
                        scope: .timing,
                        verdict: .inspect,
                        note: "check this",
                        iPhonePoseAvailable:
                            true,
                        action4PoseAvailable:
                            true,
                        equipmentAvailable:
                            true,
                        observedPlaybackDriftMS:
                            -22.5,
                        artifactBindings: [
                            ReplayReviewArtifactBindingV1(
                                role:
                                    "iphone_video",
                                sha256:
                                    "iphone"
                            ),
                        ]
                    ),
                ]
            )

        let data =
            try JSONEncoder()
                .encode(original)
        let decoded =
            try JSONDecoder()
                .decode(
                    ReplayReviewLedgerV1
                        .self,
                    from: data
                )

        XCTAssertEqual(
            decoded,
            original
        )
        XCTAssertEqual(
            decoded.flags[0]
                .windowBeforeNS,
            2_000_000_000
        )
        XCTAssertEqual(
            decoded.flags[0]
                .windowAfterNS,
            3_000_000_000
        )
    }
}
