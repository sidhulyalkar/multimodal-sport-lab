import XCTest
@testable import MotionOSAppleCapture

@MainActor
final class IndoBoardCoachEngineTests: XCTestCase {
    func testLowKneeFlexionAndTrunkMotionProducesActionableCue() {
        let coach = IndoBoardCoachEngine()

        for sequence in 0..<60 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0.10,
                    kneeOffset: 0
                ),
                elapsedSeconds: Double(sequence) * 0.1
            )
        }

        let report = coach.makeReport()

        XCTAssertEqual(
            report.headline,
            "Let the knees absorb more"
        )
        XCTAssertTrue(
            report.tip.localizedCaseInsensitiveContains("knee")
        )
        XCTAssertFalse(report.drill.isEmpty)
        XCTAssertGreaterThan(report.confidence, 0)
        XCTAssertLessThanOrEqual(report.confidence, 1)
    }

    func testShortCaptureFailsClosedInsteadOfInventingTechnique() {
        let coach = IndoBoardCoachEngine()

        for sequence in 0..<10 {
            coach.ingest(
                frame: frame(
                    sequence: UInt64(sequence),
                    shoulderOffset: 0,
                    kneeOffset: 0.04
                ),
                elapsedSeconds: Double(sequence) * 0.1
            )
        }

        let report = coach.makeReport()

        XCTAssertEqual(
            report.headline,
            "Capture more clean movement"
        )
        XCTAssertLessThan(report.confidence, 0.5)
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
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "rightHip",
                x: 0.47,
                y: 0.62,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "leftKnee",
                x: 0.43 + kneeOffset,
                y: 0.43,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "rightKnee",
                x: 0.47 - kneeOffset,
                y: 0.43,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "leftAnkle",
                x: 0.43,
                y: 0.18,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "rightAnkle",
                x: 0.47,
                y: 0.18,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "leftShoulder",
                x: 0.43 + shoulderOffset,
                y: 0.82,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "rightShoulder",
                x: 0.47 + shoulderOffset,
                y: 0.82,
                confidence: 0.95
            ),
            BodyJoint2D(
                id: "leftWrist",
                x: 0.30,
                y: 0.60,
                confidence: 0.90
            ),
            BodyJoint2D(
                id: "rightWrist",
                x: 0.70,
                y: 0.60,
                confidence: 0.90
            ),
        ]

        return BodyMovementFrame(
            sessionID: "test-session",
            sequence: sequence,
            deviceTimeNS: sequence * 100_000_000,
            source: "test",
            coordinateFrame:
                "vision_root_joint_relative_meters",
            bodyHeightM: 1.7,
            joints: [],
            imageFraming: BodyImageFraming(
                bounds: NormalizedImageBounds(
                    minX: 0.25,
                    minY: 0.10,
                    maxX: 0.75,
                    maxY: 0.92
                ),
                visibleJointCount: joints.count,
                meanConfidence: 0.95,
                visibleJointIDs: joints.map(\.id),
                coordinateFrame:
                    "vision_normalized_image_bottom_left_origin"
            ),
            imageJoints: joints
        )
    }
}
