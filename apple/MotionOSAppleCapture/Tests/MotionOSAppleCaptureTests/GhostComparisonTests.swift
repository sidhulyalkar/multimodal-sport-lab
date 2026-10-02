import XCTest
@testable import MotionOSAppleCapture

final class GhostComparisonTests: XCTestCase {
    func testTrajectoryBuilderDownsamplesPoseJournalAndPreservesSession() throws {
        let url = try makeJournal(
            sessionID: "camera-a",
            frameCount: 120,
            offset: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let trajectory = try BodyPoseTrajectoryBuilder.build(
            journalURL: url,
            sourceJournalSHA256: "abc",
            targetSampleCount: 30
        )

        XCTAssertEqual(trajectory.sessionID, "camera-a")
        XCTAssertEqual(trajectory.sourceJournalSHA256, "abc")
        XCTAssertEqual(trajectory.sourceFrameCount, 120)
        XCTAssertGreaterThanOrEqual(trajectory.samples.count, 25)
        XCTAssertLessThanOrEqual(trajectory.samples.count, 30)
        XCTAssertEqual(
            trajectory.samples.first?.progress ?? -1,
            0,
            accuracy: 0.02
        )
        XCTAssertEqual(
            trajectory.samples.last?.progress ?? -1,
            1,
            accuracy: 0.02
        )
    }

    func testIdenticalTrajectoriesHaveZeroGeometryDifference() throws {
        let url = try makeJournal(
            sessionID: "camera-a",
            frameCount: 60,
            offset: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let trajectory = try BodyPoseTrajectoryBuilder.build(
            journalURL: url,
            targetSampleCount: 30
        )

        let summary = GhostComparisonEngine.compare(
            current: trajectory,
            reference: trajectory
        )

        XCTAssertGreaterThan(summary.samplePairCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(summary.meanJointDistanceM),
            0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.medianJointDistanceM),
            0,
            accuracy: 1e-12
        )
    }

    func testChangedJointGeometryAppearsInJointDifferenceWithoutWinner() throws {
        let referenceURL = try makeJournal(
            sessionID: "reference",
            frameCount: 60,
            offset: 0
        )
        let currentURL = try makeJournal(
            sessionID: "current",
            frameCount: 60,
            offset: 0.08
        )
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: currentURL)
        }

        let reference = try BodyPoseTrajectoryBuilder.build(
            journalURL: referenceURL,
            targetSampleCount: 30
        )
        let current = try BodyPoseTrajectoryBuilder.build(
            journalURL: currentURL,
            targetSampleCount: 30
        )

        let summary = GhostComparisonEngine.compare(
            current: current,
            reference: reference
        )

        let wrist = try XCTUnwrap(
            summary.jointDifferences.first {
                $0.jointID == "leftWrist"
            }
        )

        XCTAssertEqual(
            wrist.meanDistanceM,
            0.08,
            accuracy: 0.005
        )
        XCTAssertTrue(
            summary.claimBoundary.contains(
                "not automatically better"
            )
        )
    }

    func testMixedCameraSessionsFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(
            "mixed-" + UUID().uuidString + ".jsonl"
        )
        let encoder = JSONEncoder()
        var data = Data()

        for index in 0..<4 {
            let sessionID = index < 2 ? "a" : "b"
            let event = SensorEnvelope(
                sessionID: sessionID,
                deviceID: "camera",
                stream: "/camera/pose3d",
                sequence: UInt64(index),
                deviceTimeNS:
                    UInt64(index + 1) * 100_000_000,
                payload: posePayload(
                    offset: 0,
                    phase: Double(index)
                )
            )
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try BodyPoseTrajectoryBuilder.build(
                journalURL: url
            )
        ) { error in
            XCTAssertEqual(
                error as? BodyPoseTrajectoryBuilder.BuildError,
                .mixedSessionIDs
            )
        }
    }

    private func makeJournal(
        sessionID: String,
        frameCount: Int,
        offset: Double
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(
            "pose-" + UUID().uuidString + ".jsonl"
        )
        let encoder = JSONEncoder()
        var data = Data()

        for index in 0..<frameCount {
            let event = SensorEnvelope(
                sessionID: sessionID,
                deviceID: "camera",
                stream: "/camera/pose3d",
                sequence: UInt64(index),
                deviceTimeNS:
                    UInt64(index + 1) * 100_000_000,
                payload: posePayload(
                    offset: offset,
                    phase: Double(index)
                        / Double(max(1, frameCount - 1))
                )
            )
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }

        try data.write(
            to: url,
            options: .atomic
        )
        return url
    }

    private func posePayload(
        offset: Double,
        phase: Double
    ) -> [String: JSONValue] {
        let sway = 0.04 * sin(phase * .pi * 2)

        return [
            "joints_root_relative_m": .object([
                "root": vector(0, 0, 0),
                "leftHip": vector(-0.15, 0, 0),
                "rightHip": vector(0.15, 0, 0),
                "leftKnee": vector(-0.15 + sway, -0.43, 0),
                "rightKnee": vector(0.15 + sway, -0.43, 0),
                "leftAnkle": vector(-0.15, -0.84, 0),
                "rightAnkle": vector(0.15, -0.84, 0),
                "leftShoulder": vector(-0.20, 0.48, 0),
                "rightShoulder": vector(0.20, 0.48, 0),
                "leftElbow": vector(-0.42, 0.34, 0),
                "rightElbow": vector(0.42, 0.34, 0),
                "leftWrist": vector(-0.65 + offset, 0.22, 0),
                "rightWrist": vector(0.65, 0.22, 0),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftAnkle": .string("leftKnee"),
                "rightAnkle": .string("rightKnee"),
                "leftShoulder": .string("root"),
                "rightShoulder": .string("root"),
                "leftElbow": .string("leftShoulder"),
                "rightElbow": .string("rightShoulder"),
                "leftWrist": .string("leftElbow"),
                "rightWrist": .string("rightElbow"),
            ]),
        ]
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
