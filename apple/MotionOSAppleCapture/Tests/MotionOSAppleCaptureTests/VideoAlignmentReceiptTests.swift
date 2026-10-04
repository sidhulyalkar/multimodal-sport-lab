import XCTest
@testable import MotionOSAppleCapture

final class VideoAlignmentReceiptTests: XCTestCase {
    func testBuildsPythonCompatibleVideoAlignmentReceipt() throws {
        let receipt = try VideoAlignmentReceiptBuilderV1.build(
            runID: "run-1",
            sourceFilename: "action4.mov",
            sourceSHA256: String(repeating: "a", count: 64),
            sourceByteCount: 12_345,
            videoDurationNS: 135_000_000_000,
            referenceStartNS: 0,
            referenceEndNS: 120_000_000_000,
            anchors: [
                .init(
                    label: "start",
                    videoPTSNS: 17_000_000_000,
                    referenceTimeNS: 10_000_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed_cross_view_arm_motion_peak"
                ),
                .init(
                    label: "middle",
                    videoPTSNS: 70_000_000_000,
                    referenceTimeNS: 63_000_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed_cross_view_arm_motion_peak"
                ),
                .init(
                    label: "end",
                    videoPTSNS: 121_000_000_000,
                    referenceTimeNS: 114_000_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed_cross_view_arm_motion_peak"
                ),
            ],
            sourceMetadata: [
                "review_state": "operator_accepted",
                "proposal_schema":
                    "motionos.action-camera-sync-proposal.v1",
            ]
        )

        XCTAssertEqual(
            receipt.schemaVersion,
            "motionos.video-alignment.v1"
        )
        XCTAssertTrue(receipt.coverage.passed)
        XCTAssertTrue(receipt.coverage.hasMiddleAnchor)
        XCTAssertEqual(
            receipt.clockModel.slope,
            1,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            receipt.clockModel.interceptNS,
            -7_000_000_000,
            accuracy: 1
        )
        XCTAssertEqual(
            receipt.anchorResidualsNS,
            [0, 0, 0]
        )
        XCTAssertEqual(
            receipt.trimWindow.videoStartNS,
            7_000_000_000
        )
        XCTAssertEqual(
            receipt.trimWindow.videoEndNS,
            127_000_000_000
        )

        let encoded = try JSONEncoder().encode(receipt)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoded
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["schema_version"] as? String,
            "motionos.video-alignment.v1"
        )
        XCTAssertNotNil(object["source_video"])
        XCTAssertNotNil(object["reference_window"])
        XCTAssertNotNil(object["clock_model"])
        XCTAssertNotNil(object["anchor_residuals_ns"])
        XCTAssertNotNil(object["trim_window"])
    }

    func testFinalFitUsesAllReviewedAnchors() throws {
        let receipt = try VideoAlignmentReceiptBuilderV1.build(
            runID: "run-noisy-middle",
            sourceFilename: "action4.mov",
            sourceSHA256: String(repeating: "b", count: 64),
            sourceByteCount: 50,
            videoDurationNS: 135_000_000_000,
            referenceStartNS: 0,
            referenceEndNS: 120_000_000_000,
            anchors: [
                .init(
                    label: "start",
                    videoPTSNS: 17_000_000_000,
                    referenceTimeNS: 10_000_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed"
                ),
                .init(
                    label: "middle",
                    videoPTSNS: 70_000_000_000,
                    referenceTimeNS: 63_150_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed"
                ),
                .init(
                    label: "end",
                    videoPTSNS: 121_000_000_000,
                    referenceTimeNS: 114_000_000_000,
                    uncertaintyNS: 150_000_000,
                    source: "reviewed"
                ),
            ]
        )

        XCTAssertEqual(
            receipt.clockModel.slope,
            1.0000184888450636,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            receipt.clockModel.interceptNS,
            -6_951_281_893.257744,
            accuracy: 0.01
        )
        XCTAssertEqual(
            receipt.clockModel.residualRMSNS,
            70_706_320.12178713,
            accuracy: 0.01
        )
        XCTAssertNotEqual(
            receipt.anchorResidualsNS[1],
            0
        )
    }

    func testRejectsPoorTemporalCoverage() {
        XCTAssertThrowsError(
            try VideoAlignmentReceiptBuilderV1.build(
                runID: "run-clustered",
                sourceFilename: "action4.mov",
                sourceSHA256:
                    String(repeating: "c", count: 64),
                sourceByteCount: 10,
                videoDurationNS: 120_000_000_000,
                referenceStartNS: 0,
                referenceEndNS: 120_000_000_000,
                anchors: [
                    .init(
                        label: "a",
                        videoPTSNS: 40_000_000_000,
                        referenceTimeNS: 40_000_000_000,
                        uncertaintyNS: 0,
                        source: "reviewed"
                    ),
                    .init(
                        label: "b",
                        videoPTSNS: 50_000_000_000,
                        referenceTimeNS: 50_000_000_000,
                        uncertaintyNS: 0,
                        source: "reviewed"
                    ),
                    .init(
                        label: "c",
                        videoPTSNS: 60_000_000_000,
                        referenceTimeNS: 60_000_000_000,
                        uncertaintyNS: 0,
                        source: "reviewed"
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoAlignmentReceiptError,
                .insufficientCoverage
            )
        }
    }

    func testValidationRejectsWrongSourceDigest() throws {
        let receipt = try VideoAlignmentReceiptBuilderV1.build(
            runID: "run-digest",
            sourceFilename: "action4.mov",
            sourceSHA256: String(repeating: "d", count: 64),
            sourceByteCount: 10,
            videoDurationNS: 130_000_000_000,
            referenceStartNS: 0,
            referenceEndNS: 120_000_000_000,
            anchors: [
                .init(
                    label: "start",
                    videoPTSNS: 12_000_000_000,
                    referenceTimeNS: 10_000_000_000,
                    uncertaintyNS: 0,
                    source: "reviewed"
                ),
                .init(
                    label: "middle",
                    videoPTSNS: 65_000_000_000,
                    referenceTimeNS: 63_000_000_000,
                    uncertaintyNS: 0,
                    source: "reviewed"
                ),
                .init(
                    label: "end",
                    videoPTSNS: 116_000_000_000,
                    referenceTimeNS: 114_000_000_000,
                    uncertaintyNS: 0,
                    source: "reviewed"
                ),
            ]
        )

        XCTAssertThrowsError(
            try VideoAlignmentReceiptBuilderV1.validate(
                receipt,
                sourceDigest: FileEvidenceDigest(
                    sha256:
                        String(repeating: "e", count: 64),
                    byteCount: 10
                )
            )
        )
    }
}
