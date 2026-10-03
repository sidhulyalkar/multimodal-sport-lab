import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardPrimitiveDetectorTests: XCTestCase {
    func testDetectorLearnsNeutralThenFindsRightShift() {
        let detector = IndoBoardPrimitiveDetector()

        for sequence in 0..<20 {
            _ = detector.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    pelvisOffset: 0,
                    kneeOffset: 0,
                    ankleLift: 0
                ),
                protocolBlockID: "neutral-settle"
            )
        }

        let shifted = detector.ingest(
            frame: frame(
                sequence: 30,
                pelvisOffset: 0.07,
                kneeOffset: 0,
                ankleLift: 0
            ),
            protocolBlockID: "controlled-shifts"
        )

        XCTAssertEqual(
            shifted.kind,
            .lateralShiftRight
        )
        XCTAssertGreaterThan(shifted.confidence, 0.5)
        XCTAssertNotNil(shifted.pelvisOffsetFromNeutral)
    }

    func testDetectorFindsSquatRelativeToNeutral() {
        let detector = IndoBoardPrimitiveDetector()

        for sequence in 0..<20 {
            _ = detector.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    pelvisOffset: 0,
                    kneeOffset: 0,
                    ankleLift: 0
                ),
                protocolBlockID: "neutral-settle"
            )
        }

        let squat = detector.ingest(
            frame: frame(
                sequence: 40,
                pelvisOffset: 0,
                kneeOffset: 0.10,
                ankleLift: 0
            ),
            protocolBlockID: "partial-squats"
        )

        XCTAssertEqual(squat.kind, .partialSquat)
        XCTAssertGreaterThan(
            squat.kneeFlexionDeg ?? 0,
            12
        )
    }

    func testDetectorFindsSingleLegCandidate() {
        let detector = IndoBoardPrimitiveDetector()

        for sequence in 0..<20 {
            _ = detector.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    pelvisOffset: 0,
                    kneeOffset: 0,
                    ankleLift: 0
                ),
                protocolBlockID: "neutral-settle"
            )
        }

        let singleLeg = detector.ingest(
            frame: frame(
                sequence: 50,
                pelvisOffset: 0,
                kneeOffset: 0,
                ankleLift: 0.12
            ),
            protocolBlockID: "free-balance-b"
        )

        XCTAssertEqual(
            singleLeg.kind,
            .singleLegCandidate
        )
    }

    func testPrimitiveCarriesQualifiedBoardEvidence() {
        let detector = IndoBoardPrimitiveDetector()

        for sequence in 0..<20 {
            _ = detector.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    pelvisOffset: 0,
                    kneeOffset: 0,
                    ankleLift: 0,
                    rollerAlongDeck: 0
                ),
                protocolBlockID: "neutral-settle"
            )
        }

        let shifted = detector.ingest(
            frame: frame(
                sequence: 30,
                pelvisOffset: 0.07,
                kneeOffset: 0,
                ankleLift: 0,
                rollerAlongDeck: 0.55
            ),
            protocolBlockID: "controlled-shifts"
        )

        XCTAssertEqual(
            shifted.kind,
            .lateralShiftRight
        )
        XCTAssertEqual(
            shifted.rollerAlongDeck ?? 0,
            0.55,
            accuracy: 0.02
        )
        XCTAssertEqual(
            shifted.boardStateProvenance,
            .modelEstimated
        )
        XCTAssertEqual(
            shifted.evidenceLabel,
            "camera_body_pose_plus_deck_roller_geometry"
        )
    }

    private func frame(
        sequence: UInt64,
        pelvisOffset: Double,
        kneeOffset: Double,
        ankleLift: Double,
        rollerAlongDeck: Double? = nil
    ) -> BodyMovementFrame {
        let pelvisBase = 0.45 + pelvisOffset
        let joints = [
            BodyJoint2D(
                id: "leftHip",
                x: pelvisBase - 0.02,
                y: 0.62,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightHip",
                x: pelvisBase + 0.02,
                y: 0.62,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftKnee",
                x: pelvisBase - 0.02 + kneeOffset,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightKnee",
                x: pelvisBase + 0.02 - kneeOffset,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftAnkle",
                x: pelvisBase - 0.08,
                y: 0.18 + ankleLift,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightAnkle",
                x: pelvisBase + 0.08,
                y: 0.18,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftShoulder",
                x: pelvisBase - 0.03,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightShoulder",
                x: pelvisBase + 0.03,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftWrist",
                x: pelvisBase - 0.14,
                y: 0.61,
                confidence: 0.92
            ),
            BodyJoint2D(
                id: "rightWrist",
                x: pelvisBase + 0.14,
                y: 0.61,
                confidence: 0.92
            ),
        ]

        return BodyMovementFrame(
            sessionID: "primitive-test",
            sequence: sequence,
            deviceTimeNS: sequence * 100_000_000,
            source: "test",
            coordinateFrame:
                "vision_root_joint_relative_meters",
            bodyHeightM: 1.7,
            joints: [],
            imageFraming: BodyImageFraming(
                bounds: NormalizedImageBounds(
                    minX: 0.20,
                    minY: 0.10,
                    maxX: 0.70,
                    maxY: 0.92
                ),
                visibleJointCount: joints.count,
                meanConfidence: 0.96,
                visibleJointIDs: joints.map(\.id),
                coordinateFrame:
                    "vision_normalized_image_bottom_left_origin"
            ),
            imageJoints: joints,
            indoBoardEquipment:
                rollerAlongDeck.map { normalized in
                    IndoBoardEquipmentObservation(
                        sequence: sequence,
                        deviceTimeNS:
                            sequence * 100_000_000,
                        deck: IndoBoardDeckObservation(
                            polygon: [],
                            leftEnd: .init(
                                x: 0.20,
                                y: 0.70
                            ),
                            rightEnd: .init(
                                x: 0.80,
                                y: 0.70
                            ),
                            confidence: 0.92,
                            provenance: .modelEstimated
                        ),
                        roller: IndoBoardRollerObservation(
                            center: .init(
                                x: 0.50
                                    + 0.30 * normalized,
                                y: 0.70
                            ),
                            confidence: 0.90,
                            provenance: .modelEstimated
                        ),
                        modelID: "primitive-test-board"
                    )
                }
        )
    }
}
