import XCTest
@testable import MotionOSAppleCapture

final class BodyCalibrationTests: XCTestCase {
    func testStableMultiFrameCalibrationBuildsPersonalBodyModel() throws {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<40 {
            let jitter = Double(index % 5 - 2) * 0.001
            XCTAssertTrue(
                accumulator.observe(
                    fixtureFrame(
                        sequence: UInt64(index),
                        jitter: jitter
                    )
                )
            )
        }

        XCTAssertTrue(accumulator.canFinalize)

        let result = try accumulator.finalize(
            versionID: "body-v1",
            calibratedAt: Date(timeIntervalSince1970: 10_000),
            sourceID: "vision-calibration-1"
        )

        XCTAssertEqual(result.framesSeen, 40)
        XCTAssertEqual(result.acceptedFrames, 40)
        XCTAssertGreaterThanOrEqual(
            result.model.parameters.count,
            11
        )

        let shoulder = try XCTUnwrap(
            result.model.parameter(.shoulderWidth)
        )
        XCTAssertEqual(
            shoulder.valueMeters,
            0.40,
            accuracy: 0.01
        )
        XCTAssertEqual(
            shoulder.provenance,
            .visionCalibration
        )
        XCTAssertNotNil(shoulder.uncertaintyMeters)
    }

    func testLargeOutlierDoesNotMoveRobustCenterMaterially() throws {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<30 {
            _ = accumulator.observe(
                fixtureFrame(
                    sequence: UInt64(index),
                    jitter: 0
                )
            )
        }

        var outlier = fixtureFrame(
            sequence: 31,
            jitter: 0
        )
        outlier = replacingJoint(
            in: outlier,
            id: "leftShoulder",
            position: MotionVector3(-1.2, 0.62, 0)
        )
        _ = accumulator.observe(outlier)

        let result = try accumulator.finalize(
            versionID: "body-v1",
            sourceID: "vision"
        )
        let shoulder = try XCTUnwrap(
            result.model.parameter(.shoulderWidth)
        )

        XCTAssertEqual(
            shoulder.valueMeters,
            0.40,
            accuracy: 0.02
        )
    }

    func testPartialFramesDoNotPassCoverageGate() {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<50 {
            _ = accumulator.observe(
                BodyMovementFrame(
                    sessionID: "cal",
                    sequence: UInt64(index),
                    deviceTimeNS: UInt64(index),
                    source: "fixture",
                    coordinateFrame: "root",
                    bodyHeightM: 1.70,
                    joints: [
                        BodyJoint3D(
                            id: "root",
                            parentID: nil,
                            position: MotionVector3(0, 0, 0)
                        ),
                        BodyJoint3D(
                            id: "topHead",
                            parentID: "root",
                            position: MotionVector3(0, 0.85, 0)
                        ),
                    ]
                )
            )
        }

        XCTAssertFalse(accumulator.canFinalize)
        XCTAssertEqual(accumulator.acceptedFrames, 0)
    }

    func testLeftAndRightSegmentLengthsRemainSeparate() throws {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<30 {
            _ = accumulator.observe(
                asymmetricFrame(sequence: UInt64(index))
            )
        }

        let result = try accumulator.finalize(
            versionID: "body-v1",
            sourceID: "vision"
        )

        let left = try XCTUnwrap(
            result.model.parameter(.leftForearmLength)
        )
        let right = try XCTUnwrap(
            result.model.parameter(.rightForearmLength)
        )

        XCTAssertNotEqual(
            left.valueMeters,
            right.valueMeters
        )
        XCTAssertGreaterThan(
            right.valueMeters,
            left.valueMeters
        )
    }

    func testTooFewFramesCannotFinalize() {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<10 {
            _ = accumulator.observe(
                fixtureFrame(
                    sequence: UInt64(index),
                    jitter: 0
                )
            )
        }

        XCTAssertFalse(accumulator.canFinalize)
        XCTAssertThrowsError(
            try accumulator.finalize(
                versionID: "body-v1",
                sourceID: "vision"
            )
        )
    }

    private func fixtureFrame(
        sequence: UInt64,
        jitter: Double
    ) -> BodyMovementFrame {
        BodyMovementFrame(
            sessionID: "calibration",
            sequence: sequence,
            deviceTimeNS: sequence * 100_000_000,
            source: "fixture",
            coordinateFrame: "vision_root_joint_relative_meters",
            bodyHeightM: 1.70 + jitter,
            joints: [
                .init(id: "root", parentID: nil, position: .init(0, 0, 0)),
                .init(id: "centerShoulder", parentID: "root", position: .init(0, 0.48 + jitter, 0)),
                .init(id: "leftShoulder", parentID: "centerShoulder", position: .init(-0.20 + jitter, 0.48, 0)),
                .init(id: "rightShoulder", parentID: "centerShoulder", position: .init(0.20 + jitter, 0.48, 0)),
                .init(id: "leftElbow", parentID: "leftShoulder", position: .init(-0.45, 0.34, 0)),
                .init(id: "rightElbow", parentID: "rightShoulder", position: .init(0.45, 0.34, 0)),
                .init(id: "leftWrist", parentID: "leftElbow", position: .init(-0.67, 0.22, 0)),
                .init(id: "rightWrist", parentID: "rightElbow", position: .init(0.67, 0.22, 0)),
                .init(id: "leftHip", parentID: "root", position: .init(-0.15, 0, 0)),
                .init(id: "rightHip", parentID: "root", position: .init(0.15, 0, 0)),
                .init(id: "leftKnee", parentID: "leftHip", position: .init(-0.15, -0.43, 0)),
                .init(id: "rightKnee", parentID: "rightHip", position: .init(0.15, -0.43, 0)),
                .init(id: "leftAnkle", parentID: "leftKnee", position: .init(-0.15, -0.84, 0)),
                .init(id: "rightAnkle", parentID: "rightKnee", position: .init(0.15, -0.84, 0)),
            ]
        )
    }

    private func asymmetricFrame(
        sequence: UInt64
    ) -> BodyMovementFrame {
        let base = fixtureFrame(
            sequence: sequence,
            jitter: 0
        )
        return replacingJoint(
            in: base,
            id: "rightWrist",
            position: MotionVector3(0.72, 0.19, 0)
        )
    }

    private func replacingJoint(
        in frame: BodyMovementFrame,
        id: String,
        position: MotionVector3
    ) -> BodyMovementFrame {
        let joints = frame.joints.map { joint in
            guard joint.id == id else { return joint }
            return BodyJoint3D(
                id: joint.id,
                parentID: joint.parentID,
                position: position
            )
        }

        return BodyMovementFrame(
            sessionID: frame.sessionID,
            sequence: frame.sequence,
            deviceTimeNS: frame.deviceTimeNS,
            source: frame.source,
            coordinateFrame: frame.coordinateFrame,
            bodyHeightM: frame.bodyHeightM,
            joints: joints,
            pelvisReference: frame.pelvisReference,
            centerOfMass: frame.centerOfMass,
            supportPoints: frame.supportPoints,
            muscleActivations: frame.muscleActivations
        )
    }
}
