import XCTest
@testable import MotionOSAppleCapture

final class MobilityProtocolTests: XCTestCase {
    func testGuidedWindowsProduceMobilityEvidence() throws {
        var accumulator = MobilityProtocolAccumulator()
        var sequence: UInt64 = 0

        for sample in 0..<20 {
            let elapsed = 5.0 + Double(sample) * 0.30
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    leftElbow: MotionVector3(
                        -0.20,
                        0.48 + Double(sample) * 0.025,
                        0
                    )
                ),
                elapsedSeconds: elapsed
            )
            sequence += 1
        }

        for sample in 0..<20 {
            let elapsed = 12.0 + Double(sample) * 0.30
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    rightElbow: MotionVector3(
                        0.20,
                        0.48 + Double(sample) * 0.023,
                        0
                    )
                ),
                elapsedSeconds: elapsed
            )
            sequence += 1
        }

        for sample in 0..<20 {
            let elapsed = 19.0 + Double(sample) * 0.35
            let kneeY =
                -0.43 + Double(sample) * 0.009
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    kneeY: kneeY,
                    kneeZ: 0.22
                ),
                elapsedSeconds: elapsed
            )
            sequence += 1
        }

        for sample in 0..<20 {
            let elapsed = 27.0 + Double(sample) * 0.45
            let z = Double(sample) * 0.01
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    leftShoulder:
                        MotionVector3(-0.20, 0.48, -z),
                    rightShoulder:
                        MotionVector3(0.20, 0.48, z)
                ),
                elapsedSeconds: elapsed
            )
            sequence += 1
        }

        let result = accumulator.result(
            challengeID: "mobility-1",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            cameraSessionID: "camera"
        )

        XCTAssertTrue(result.hasUsableCoverage)
        XCTAssertNotNil(result.maximumLeftShoulderElevationDegrees)
        XCTAssertNotNil(result.maximumRightShoulderElevationDegrees)
        XCTAssertNotNil(result.minimumMeanKneeAngleDegrees)
        XCTAssertNotNil(result.maximumTrunkTwistProxyDegrees)
        XCTAssertNotNil(result.shoulderElevationAsymmetryDegrees)

        let evidence = result.personaEvidence()
        XCTAssertTrue(evidence.completed)
        XCTAssertEqual(evidence.metrics.count, 5)
        XCTAssertTrue(
            evidence.metrics.allSatisfy {
                $0.dimension == .mobility
                    && $0.provenance == .derived
            }
        )
    }

    func testMissingGuidedWindowsDoesNotContributeCompletedPersonaEvidence() {
        var accumulator = MobilityProtocolAccumulator()

        for sample in 0..<20 {
            _ = accumulator.observe(
                frame(
                    sequence: UInt64(sample),
                    leftElbow: MotionVector3(
                        -0.20,
                        0.80,
                        0
                    )
                ),
                elapsedSeconds: 5.0 + Double(sample) * 0.30
            )
        }

        let result = accumulator.result(
            challengeID: "partial",
            capturedAt: Date(),
            cameraSessionID: "camera"
        )

        XCTAssertFalse(result.hasUsableCoverage)
        XCTAssertFalse(result.personaEvidence().completed)
    }

    func testDuplicateFrameIsRejected() {
        var accumulator = MobilityProtocolAccumulator()
        let frame = frame(
            sequence: 1,
            leftElbow: MotionVector3(-0.2, 0.8, 0)
        )

        XCTAssertTrue(
            accumulator.observe(
                frame,
                elapsedSeconds: 6
            )
        )
        XCTAssertFalse(
            accumulator.observe(
                frame,
                elapsedSeconds: 6.1
            )
        )
    }

    func testShoulderAsymmetryIsAbsoluteDifference() throws {
        var accumulator = MobilityProtocolAccumulator()
        var sequence: UInt64 = 0

        for sample in 0..<12 {
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    leftElbow: MotionVector3(-0.20, 0.90, 0)
                ),
                elapsedSeconds: 5.1 + Double(sample) * 0.4
            )
            sequence += 1
        }

        for sample in 0..<12 {
            _ = accumulator.observe(
                frame(
                    sequence: sequence,
                    rightElbow: MotionVector3(0.20, 0.72, 0)
                ),
                elapsedSeconds: 12.1 + Double(sample) * 0.4
            )
            sequence += 1
        }

        let result = accumulator.result(
            challengeID: "asym",
            capturedAt: Date(),
            cameraSessionID: "camera"
        )

        let left = try XCTUnwrap(
            result.maximumLeftShoulderElevationDegrees
        )
        let right = try XCTUnwrap(
            result.maximumRightShoulderElevationDegrees
        )
        let asymmetry = try XCTUnwrap(
            result.shoulderElevationAsymmetryDegrees
        )

        XCTAssertEqual(
            asymmetry,
            abs(left - right),
            accuracy: 1e-9
        )
    }

    private func frame(
        sequence: UInt64,
        leftShoulder: MotionVector3 = .init(-0.20, 0.48, 0),
        rightShoulder: MotionVector3 = .init(0.20, 0.48, 0),
        leftElbow: MotionVector3 = .init(-0.20, 0.10, 0),
        rightElbow: MotionVector3 = .init(0.20, 0.10, 0),
        kneeY: Double = -0.43,
        kneeZ: Double = 0
    ) -> BodyMovementFrame {
        BodyMovementFrame(
            sessionID: "mobility-camera",
            sequence: sequence,
            deviceTimeNS: sequence * 100_000_000,
            source: "fixture",
            coordinateFrame:
                "vision_root_joint_relative_meters",
            bodyHeightM: nil,
            joints: [
                .init(
                    id: "root",
                    parentID: nil,
                    position: .init(0, 0, 0)
                ),
                .init(
                    id: "leftShoulder",
                    parentID: "root",
                    position: leftShoulder
                ),
                .init(
                    id: "rightShoulder",
                    parentID: "root",
                    position: rightShoulder
                ),
                .init(
                    id: "leftElbow",
                    parentID: "leftShoulder",
                    position: leftElbow
                ),
                .init(
                    id: "rightElbow",
                    parentID: "rightShoulder",
                    position: rightElbow
                ),
                .init(
                    id: "leftHip",
                    parentID: "root",
                    position: .init(-0.15, 0, 0)
                ),
                .init(
                    id: "rightHip",
                    parentID: "root",
                    position: .init(0.15, 0, 0)
                ),
                .init(
                    id: "leftKnee",
                    parentID: "leftHip",
                    position: .init(-0.15, kneeY, kneeZ)
                ),
                .init(
                    id: "rightKnee",
                    parentID: "rightHip",
                    position: .init(0.15, kneeY, kneeZ)
                ),
                .init(
                    id: "leftAnkle",
                    parentID: "leftKnee",
                    position: .init(-0.15, -0.84, 0)
                ),
                .init(
                    id: "rightAnkle",
                    parentID: "rightKnee",
                    position: .init(0.15, -0.84, 0)
                ),
            ]
        )
    }
}
