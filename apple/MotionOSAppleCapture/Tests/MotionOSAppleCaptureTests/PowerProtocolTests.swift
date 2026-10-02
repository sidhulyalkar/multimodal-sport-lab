import XCTest
@testable import MotionOSAppleCapture

final class PowerProtocolTests: XCTestCase {
    func testCameraOriginMatrixTranslationBecomesTypedRootPosition() throws {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": vector(0, 0, 0),
                "leftHip": vector(-0.1, 0, 0),
                "rightHip": vector(0.1, 0, 0),
                "leftKnee": vector(-0.1, -0.4, 0),
                "rightKnee": vector(0.1, -0.4, 0),
                "leftAnkle": vector(-0.1, -0.8, 0),
                "rightAnkle": vector(0.1, -0.8, 0),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftAnkle": .string("leftKnee"),
                "rightAnkle": .string("rightKnee"),
            ]),
            "camera_origin_matrix": .array([
                .array([.number(1), .number(0), .number(0), .number(0.25)]),
                .array([.number(0), .number(1), .number(0), .number(1.10)]),
                .array([.number(0), .number(0), .number(1), .number(-2.40)]),
                .array([.number(0), .number(0), .number(0), .number(1)]),
            ]),
            "body_height_m": .number(1.8),
            "height_estimation": .string("reference"),
        ]

        let frame = try XCTUnwrap(
            BodyMovementFrameParser.parseVisionPose(
                payload: payload,
                sessionID: "vision",
                sequence: 1,
                deviceTimeNS: 100
            )
        )

        let root = try XCTUnwrap(
            frame.rootPositionCameraM
        )
        XCTAssertEqual(
            root.x,
            0.25,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            root.y,
            1.10,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            root.z,
            -2.40,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            frame.bodyHeightEstimation,
            "reference"
        )
    }

    func testThreeStandardAttemptsProduceKinematicProxyResult() throws {
        var accumulator = PowerProtocolAccumulator()

        for window in PowerProtocolAccumulator.attemptWindows {
            for sample in 0..<20 {
                let elapsed =
                    window.startSeconds
                        + Double(sample) * 0.20
                _ = accumulator.observe(
                    fixtureFrame(
                        sequence:
                            UInt64(window.index * 100 + sample),
                        timeSeconds: elapsed,
                        rootY:
                            1.0
                                + jumpWave(sample: sample),
                        kneeYOffset:
                            sample < 6 ? 0.10 : 0
                    ),
                    elapsedSeconds: elapsed
                )
            }
        }

        let result = accumulator.result(
            challengeID: "power-1",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            cameraSessionID: "camera-1"
        )

        XCTAssertEqual(result.attempts.count, 3)
        XCTAssertEqual(result.validAttemptCount, 3)
        XCTAssertNotNil(result.medianPeakRootSpeedCameraMPS)
        XCTAssertNotNil(result.medianRootTravelRangeCameraM)
        XCTAssertNotNil(result.peakSpeedCoefficientOfVariation)
        XCTAssertTrue(
            result.attempts.allSatisfy {
                ($0.minimumMeanKneeAngleDegrees ?? 180) < 180
            }
        )

        let evidence = result.personaEvidence()
        XCTAssertTrue(evidence.completed)
        XCTAssertEqual(evidence.metrics.count, 3)
        XCTAssertTrue(
            evidence.metrics.allSatisfy {
                $0.dimension == .power
                    && $0.provenance == .derived
            }
        )
    }

    func testOneAttemptDoesNotQualifyPersonaEvidenceAsCompleted() {
        var accumulator = PowerProtocolAccumulator()
        let window = PowerProtocolAccumulator.attemptWindows[0]

        for sample in 0..<12 {
            let elapsed =
                window.startSeconds
                    + Double(sample) * 0.20
            _ = accumulator.observe(
                fixtureFrame(
                    sequence: UInt64(sample),
                    timeSeconds: elapsed,
                    rootY:
                        1.0 + jumpWave(sample: sample),
                    kneeYOffset: 0
                ),
                elapsedSeconds: elapsed
            )
        }

        let result = accumulator.result(
            challengeID: "incomplete",
            capturedAt: Date(),
            cameraSessionID: "camera"
        )

        XCTAssertEqual(result.validAttemptCount, 1)
        XCTAssertFalse(result.personaEvidence().completed)
    }

    func testDuplicateFrameCannotInflateAttemptCoverage() {
        var accumulator = PowerProtocolAccumulator()
        let elapsed = 6.0
        let frame = fixtureFrame(
            sequence: 1,
            timeSeconds: elapsed,
            rootY: 1.0,
            kneeYOffset: 0
        )

        XCTAssertTrue(
            accumulator.observe(
                frame,
                elapsedSeconds: elapsed
            )
        )
        XCTAssertFalse(
            accumulator.observe(
                frame,
                elapsedSeconds: elapsed
            )
        )

        let result = accumulator.result(
            challengeID: "dup",
            capturedAt: Date(),
            cameraSessionID: "camera"
        )
        XCTAssertEqual(
            result.attempts[0].validFrameCount,
            1
        )
    }

    func testReferenceHeightIsNotUsedAsPersonalStandingHeight() throws {
        var accumulator = BodyCalibrationAccumulator()

        for index in 0..<30 {
            _ = accumulator.observe(
                bodyCalibrationFrame(
                    sequence: UInt64(index),
                    heightEstimation: "reference"
                )
            )
        }

        let result = try accumulator.finalize(
            versionID: "body-no-height",
            sourceID: "vision"
        )
        XCTAssertNil(
            result.model.parameter(.standingHeight)
        )
    }

    private func jumpWave(
        sample: Int
    ) -> Double {
        let x = Double(sample) / 19.0
        return 0.28 * sin(x * .pi)
    }

    private func fixtureFrame(
        sequence: UInt64,
        timeSeconds: Double,
        rootY: Double,
        kneeYOffset: Double
    ) -> BodyMovementFrame {
        let kneeY = -0.42 + kneeYOffset

        return BodyMovementFrame(
            sessionID: "camera",
            sequence: sequence,
            deviceTimeNS:
                UInt64(timeSeconds * 1_000_000_000),
            source: "fixture",
            coordinateFrame:
                "vision_root_joint_relative_meters",
            bodyHeightM: 1.8,
            bodyHeightEstimation: "reference",
            rootPositionCameraM:
                MotionVector3(0, rootY, -2),
            joints: [
                .init(
                    id: "root",
                    parentID: nil,
                    position: .init(0, 0, 0)
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
                    position: .init(-0.15, kneeY, 0.08)
                ),
                .init(
                    id: "rightKnee",
                    parentID: "rightHip",
                    position: .init(0.15, kneeY, 0.08)
                ),
                .init(
                    id: "leftAnkle",
                    parentID: "leftKnee",
                    position: .init(-0.15, -0.83, 0)
                ),
                .init(
                    id: "rightAnkle",
                    parentID: "rightKnee",
                    position: .init(0.15, -0.83, 0)
                ),
            ]
        )
    }

    private func bodyCalibrationFrame(
        sequence: UInt64,
        heightEstimation: String
    ) -> BodyMovementFrame {
        BodyMovementFrame(
            sessionID: "cal",
            sequence: sequence,
            deviceTimeNS: sequence * 100_000_000,
            source: "fixture",
            coordinateFrame: "root",
            bodyHeightM: 1.8,
            bodyHeightEstimation: heightEstimation,
            joints: [
                .init(id: "root", parentID: nil, position: .init(0, 0, 0)),
                .init(id: "centerShoulder", parentID: "root", position: .init(0, 0.48, 0)),
                .init(id: "leftShoulder", parentID: "centerShoulder", position: .init(-0.2, 0.48, 0)),
                .init(id: "rightShoulder", parentID: "centerShoulder", position: .init(0.2, 0.48, 0)),
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

    private func vector(
        _ x: Double,
        _ y: Double,
        _ z: Double
    ) -> JSONValue {
        .array([
            .number(x),
            .number(y),
            .number(z),
        ])
    }
}
