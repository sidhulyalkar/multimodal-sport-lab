import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardBoardAwareCoachTests: XCTestCase {
    func testBoardEvidenceSelectsDeckCenteredIntervention() {
        let coach = IndoBoardCoachEngine()

        for index in 0..<80 {
            let position =
                sin(Double(index) * 0.22) * 0.76
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    16 + Double(index) * 0.1
            )
        }

        let intervention = coach.makeIntervention()

        XCTAssertEqual(
            intervention?.id,
            "earlier-smaller-board-recovery"
        )
        XCTAssertEqual(
            intervention?.targetMetric,
            .rollerExcursionP90
        )
        XCTAssertEqual(
            intervention?.desiredDirection,
            .decrease
        )
    }

    func testBoardAwareRetryScoresReducedExcursionAsImproved() {
        let coach = IndoBoardCoachEngine()

        for index in 0..<80 {
            let position =
                sin(Double(index) * 0.22) * 0.76
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    16 + Double(index) * 0.1
            )
        }

        guard let intervention = coach.makeIntervention()
        else {
            XCTFail("Expected board-aware intervention")
            return
        }

        for index in 80..<160 {
            let local = index - 80
            let position =
                sin(Double(local) * 0.22) * 0.36
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    86 + Double(local) * 0.1
            )
        }

        let report = coach.makeReport(
            intervention: intervention
        )

        XCTAssertEqual(
            report.experimentResult?.outcome,
            .improved
        )
        XCTAssertEqual(
            report.experimentResult?.targetMetric,
            .rollerExcursionP90
        )
        XCTAssertLessThan(
            report.experimentResult?.relativeChange ?? 0,
            -0.25
        )
        XCTAssertNotNil(
            report.numericMetrics[
                "board_center_time_fraction"
            ]
        )
        XCTAssertTrue(
            report.evidenceLabel
                .localizedCaseInsensitiveContains(
                    "deck + roller"
                )
        )
    }

    func testSparseBoardTrackingDoesNotDriveIntervention() {
        let coach = IndoBoardCoachEngine()

        for index in 0..<80 {
            let position: Double? =
                index < 24
                    ? sin(Double(index) * 0.22) * 0.76
                    : nil
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    16 + Double(index) * 0.1
            )
        }

        let intervention = coach.makeIntervention()

        XCTAssertNotEqual(
            intervention?.targetMetric,
            .rollerExcursionP90
        )
    }

    func testBoardCueFailsClosedWhenRetryTrackingDropsOut() {
        let coach = IndoBoardCoachEngine()

        for index in 0..<80 {
            let position =
                sin(Double(index) * 0.22) * 0.76
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    16 + Double(index) * 0.1
            )
        }

        guard let intervention = coach.makeIntervention()
        else {
            XCTFail("Expected board-aware intervention")
            return
        }
        XCTAssertEqual(
            intervention.targetMetric,
            .rollerExcursionP90
        )

        for index in 80..<160 {
            let local = index - 80
            let position: Double? =
                local < 20
                    ? sin(Double(local) * 0.22) * 0.36
                    : nil
            coach.ingest(
                frame: frame(
                    sequence: index,
                    rollerPosition: position
                ),
                elapsedSeconds:
                    86 + Double(local) * 0.1
            )
        }

        let report = coach.makeReport(
            intervention: intervention
        )

        XCTAssertEqual(
            report.experimentResult?.outcome,
            .insufficientEvidence
        )
        XCTAssertTrue(
            report.experimentResult?.summary
                .localizedCaseInsensitiveContains(
                    "tracking visible"
                ) == true
        )
    }

    private func frame(
        sequence: Int,
        rollerPosition: Double?
    ) -> BodyMovementFrame {
        let joints = [
            BodyJoint2D(
                id: "leftHip",
                x: 0.43,
                y: 0.62,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightHip",
                x: 0.47,
                y: 0.62,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftKnee",
                x: 0.43,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightKnee",
                x: 0.47,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftAnkle",
                x: 0.38,
                y: 0.18,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightAnkle",
                x: 0.52,
                y: 0.18,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftShoulder",
                x: 0.42,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightShoulder",
                x: 0.48,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftWrist",
                x: 0.31,
                y: 0.60,
                confidence: 0.92
            ),
            BodyJoint2D(
                id: "rightWrist",
                x: 0.59,
                y: 0.60,
                confidence: 0.92
            ),
        ]

        // For deck endpoints x=0.2...0.8, this mapping makes the
        // estimator recover rollerPosition in approximately -1...+1.
        let rollerX = rollerPosition.map {
            0.50 + 0.30 * $0
        }

        return BodyMovementFrame(
            sessionID: "board-aware-coach",
            sequence: UInt64(sequence),
            deviceTimeNS:
                UInt64(sequence) * 100_000_000,
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
                rollerX.map { rollerX in
                    IndoBoardEquipmentObservation(
                        sequence: UInt64(sequence),
                        deviceTimeNS:
                            UInt64(sequence)
                                * 100_000_000,
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
                                x: rollerX,
                                y: 0.70
                            ),
                            confidence: 0.90,
                            provenance: .modelEstimated
                        ),
                        modelID: "test-equipment"
                    )
                }
        )
    }
}
