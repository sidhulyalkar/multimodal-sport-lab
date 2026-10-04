import XCTest
@testable import MotionOSAppleCapture

final class ExternalVideoPoseTrackTests: XCTestCase {
    func testInterpolatesCommonJointsBetweenFrames() throws {
        let track = makeTrack(
            frames: [
                frame(
                    time: 1_000_000_000,
                    joints: [
                        joint("leftWrist", 0.20, 0.40, 0.8),
                        joint("rightWrist", 0.80, 0.40, 0.9),
                    ]
                ),
                frame(
                    time: 1_200_000_000,
                    joints: [
                        joint("leftWrist", 0.40, 0.60, 1.0),
                        joint("rightWrist", 0.60, 0.60, 0.7),
                    ]
                ),
            ]
        )

        let value = try XCTUnwrap(
            track.interpolatedFrame(
                at: 1_100_000_000
            )
        )
        let joints = value.jointMap
        let left = try XCTUnwrap(
            joints["leftWrist"]
        )
        let right = try XCTUnwrap(
            joints["rightWrist"]
        )

        XCTAssertEqual(
            left.x,
            0.30,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            left.y,
            0.50,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            left.confidence,
            0.90,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            right.x,
            0.70,
            accuracy: 1e-12
        )
    }

    func testDoesNotBridgeLargePoseGap() {
        let track = makeTrack(
            frames: [
                frame(
                    time: 1_000_000_000,
                    joints: [
                        joint("root", 0.5, 0.5, 1),
                    ]
                ),
                frame(
                    time: 2_000_000_000,
                    joints: [
                        joint("root", 0.6, 0.5, 1),
                    ]
                ),
            ]
        )

        XCTAssertNil(
            track.interpolatedFrame(
                at: 1_500_000_000
            )
        )
    }

    func testFallsBackToNearbyFrameAtTrackEdge() throws {
        let track = makeTrack(
            frames: [
                frame(
                    time: 1_000_000_000,
                    joints: [
                        joint("root", 0.5, 0.5, 1),
                    ]
                ),
            ]
        )

        let value = try XCTUnwrap(
            track.interpolatedFrame(
                at: 1_100_000_000
            )
        )
        XCTAssertEqual(
            value.sourcePTSNS,
            1_000_000_000
        )
    }

    func testCoverageAndMeanConfidenceAreDerived() {
        let track = makeTrack(
            durationNS: 10_000_000_000,
            frames: [
                frame(
                    time: 1_000_000_000,
                    joints: [
                        joint("a", 0, 0, 0.5),
                        joint("b", 0, 0, 1.0),
                    ]
                ),
                frame(
                    time: 9_000_000_000,
                    joints: [
                        joint("a", 0, 0, 1.0),
                        joint("b", 0, 0, 1.0),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            track.temporalCoverageFraction,
            0.8,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            track.meanConfidence,
            0.875,
            accuracy: 1e-12
        )
        XCTAssertEqual(track.frameCount, 2)
    }

    func testCarriesNearbyQREquipmentWithoutInterpolatingGeometry() throws {
        let equipment =
            IndoBoardFiducialEquipmentBuilder
                .makeObservation(
                    detections: [
                        .init(
                            marker: .deckLeft,
                            center:
                                NormalizedImagePoint2D(
                                    x: 0.2,
                                    y: 0.7
                                ),
                            confidence: 0.9
                        ),
                        .init(
                            marker: .deckRight,
                            center:
                                NormalizedImagePoint2D(
                                    x: 0.8,
                                    y: 0.7
                                ),
                            confidence: 0.9
                        ),
                        .init(
                            marker: .rollerCenter,
                            center:
                                NormalizedImagePoint2D(
                                    x: 0.5,
                                    y: 0.55
                                ),
                            confidence: 0.85
                        ),
                    ],
                    sequence: 1,
                    deviceTimeNS:
                        1_000_000_000
                )

        let track = makeTrack(
            frames: [
                ExternalVideoPoseFrame(
                    sourcePTSNS:
                        1_000_000_000,
                    joints: [
                        joint(
                            "root",
                            0.5,
                            0.5,
                            1
                        ),
                    ],
                    indoBoardEquipment:
                        equipment,
                    visibleFiducials: [
                        .deckLeft,
                        .deckRight,
                        .rollerCenter,
                    ]
                ),
                ExternalVideoPoseFrame(
                    sourcePTSNS:
                        1_200_000_000,
                    joints: [
                        joint(
                            "root",
                            0.6,
                            0.5,
                            1
                        ),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            track.equipmentFrameCount,
            1
        )
        XCTAssertEqual(
            track.equipmentCoverageFraction,
            0.5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            track.fiducialFrameCount,
            1
        )

        let near = try XCTUnwrap(
            track.interpolatedFrame(
                at: 1_080_000_000
            )
        )
        XCTAssertNotNil(
            near.indoBoardEquipment
        )
        XCTAssertEqual(
            Set(near.visibleFiducials),
            Set([
                .deckLeft,
                .deckRight,
                .rollerCenter,
            ])
        )

        let farther = try XCTUnwrap(
            track.interpolatedFrame(
                at: 1_190_000_000,
                maximumNearestDistanceNS:
                    50_000_000
            )
        )
        XCTAssertNil(
            farther.indoBoardEquipment
        )
    }

    func testFramesAreSortedAndJointConfidenceClamped() {
        let track = makeTrack(
            frames: [
                frame(
                    time: 2,
                    joints: [
                        joint("a", 0, 0, 3),
                    ]
                ),
                frame(
                    time: 1,
                    joints: [
                        joint("a", 0, 0, -2),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            track.frames.map(\.sourcePTSNS),
            [1, 2]
        )
        XCTAssertEqual(
            track.frames[0].joints[0].confidence,
            0
        )
        XCTAssertEqual(
            track.frames[1].joints[0].confidence,
            1
        )
    }

    private func makeTrack(
        durationNS: UInt64 = 3_000_000_000,
        frames: [ExternalVideoPoseFrame]
    ) -> ExternalVideoPoseTrack {
        ExternalVideoPoseTrack(
            runID: "run-1",
            sourceID: "action4",
            sourceVideoSHA256:
                String(repeating: "a", count: 64),
            sourceVideoByteCount: 123,
            sourceDurationNS: durationNS,
            analyzerID:
                "apple.vision.human-body-pose",
            analyzerVersion: "v1",
            sampleIntervalSeconds: 0.1,
            coordinateFrame:
                "source_image_normalized_origin_lower_left_after_orientation",
            frames: frames,
            createdAtUTC:
                "2026-10-04T23:00:00Z"
        )
    }

    private func frame(
        time: UInt64,
        joints: [BodyJoint2D]
    ) -> ExternalVideoPoseFrame {
        ExternalVideoPoseFrame(
            sourcePTSNS: time,
            joints: joints
        )
    }

    private func joint(
        _ id: String,
        _ x: Double,
        _ y: Double,
        _ confidence: Double
    ) -> BodyJoint2D {
        BodyJoint2D(
            id: id,
            x: x,
            y: y,
            confidence: confidence
        )
    }
}
