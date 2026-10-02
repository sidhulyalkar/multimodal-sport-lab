import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardAdaptiveCoachTests: XCTestCase {
    func testInterventionUsesFirstHalfEvidence() {
        let coach = IndoBoardCoachEngine()

        for sequence in 0..<120 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0.10,
                    kneeOffset: 0
                ),
                elapsedSeconds: 16 + Double(sequence) * 0.1
            )
        }

        let intervention = coach.makeIntervention()

        XCTAssertEqual(
            intervention?.id,
            "soft-knee-quiet-shoulders"
        )
        XCTAssertEqual(
            intervention?.targetMetric,
            .trunkExcursionP90
        )
        XCTAssertEqual(
            intervention?.desiredDirection,
            .decrease
        )
    }

    func testCoachedRetryMeasuresWithinSessionResponse() {
        let coach = IndoBoardCoachEngine()

        for sequence in 0..<100 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0.10,
                    kneeOffset: 0
                ),
                elapsedSeconds: 16 + Double(sequence) * 0.1
            )
        }

        guard let intervention = coach.makeIntervention() else {
            XCTFail("Expected adaptive intervention")
            return
        }

        for sequence in 100..<200 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0.03,
                    kneeOffset: 0.03
                ),
                elapsedSeconds:
                    86 + Double(sequence - 100) * 0.1
            )
        }

        let report = coach.makeReport(
            intervention: intervention
        )

        XCTAssertEqual(
            report.experimentResult?.outcome,
            .improved
        )
        XCTAssertLessThan(
            report.experimentResult?.relativeChange ?? 0,
            -0.05
        )
        XCTAssertEqual(
            report.intervention?.id,
            intervention.id
        )
        XCTAssertTrue(
            report.observation.localizedCaseInsensitiveContains(
                "coached retry"
            )
        )
    }

    func testInsufficientRetryEvidenceFailsClosed() {
        let coach = IndoBoardCoachEngine()

        for sequence in 0..<100 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0.10,
                    kneeOffset: 0
                ),
                elapsedSeconds: 16 + Double(sequence) * 0.1
            )
        }

        guard let intervention = coach.makeIntervention() else {
            XCTFail("Expected adaptive intervention")
            return
        }

        let report = coach.makeReport(
            intervention: intervention
        )

        XCTAssertEqual(
            report.experimentResult?.outcome,
            .insufficientEvidence
        )
    }

    private func frame(
        sequence: UInt64,
        shoulderOffset: Double,
        kneeOffset: Double
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
                x: 0.43 + kneeOffset,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightKnee",
                x: 0.47 - kneeOffset,
                y: 0.43,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftAnkle",
                x: 0.43,
                y: 0.18,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightAnkle",
                x: 0.47,
                y: 0.18,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftShoulder",
                x: 0.43 + shoulderOffset,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "rightShoulder",
                x: 0.47 + shoulderOffset,
                y: 0.82,
                confidence: 0.96
            ),
            BodyJoint2D(
                id: "leftWrist",
                x: 0.30,
                y: 0.60,
                confidence: 0.92
            ),
            BodyJoint2D(
                id: "rightWrist",
                x: 0.70,
                y: 0.60,
                confidence: 0.92
            ),
        ]

        return BodyMovementFrame(
            sessionID: "adaptive-coach-test",
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
            imageJoints: joints
        )
    }
}
