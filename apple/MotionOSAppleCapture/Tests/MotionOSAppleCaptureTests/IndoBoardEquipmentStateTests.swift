import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardEquipmentStateTests: XCTestCase {
    func testCenteredRollerProducesHighCenterProximity() {
        let observation = IndoBoardEquipmentObservation(
            sequence: 12,
            deviceTimeNS: 1_200_000_000,
            deck: IndoBoardDeckObservation(
                polygon: [],
                leftEnd: .init(x: 0.20, y: 0.60),
                rightEnd: .init(x: 0.80, y: 0.60),
                confidence: 0.92,
                provenance: .manualAnnotated
            ),
            roller: IndoBoardRollerObservation(
                center: .init(x: 0.50, y: 0.60),
                confidence: 0.88,
                provenance: .manualAnnotated
            )
        )

        let state = IndoBoardBalanceStateEstimator.estimate(
            from: observation
        )

        XCTAssertNotNil(state)
        XCTAssertEqual(
            state?.rollerAlongDeck ?? 1,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            state?.centerProximity ?? 0,
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            state?.confidence ?? 0,
            0.88,
            accuracy: 0.001
        )
        XCTAssertEqual(
            state?.provenance,
            .manualAnnotated
        )
    }

    func testRollerNearRightEndMapsTowardPositiveOne() {
        let observation = IndoBoardEquipmentObservation(
            sequence: 1,
            deviceTimeNS: 1,
            deck: IndoBoardDeckObservation(
                polygon: [],
                leftEnd: .init(x: 0.10, y: 0.50),
                rightEnd: .init(x: 0.90, y: 0.50),
                confidence: 0.9,
                provenance: .modelEstimated
            ),
            roller: IndoBoardRollerObservation(
                center: .init(x: 0.82, y: 0.50),
                confidence: 0.8,
                provenance: .modelEstimated
            )
        )

        let state = IndoBoardBalanceStateEstimator.estimate(
            from: observation
        )

        XCTAssertGreaterThan(
            state?.rollerAlongDeck ?? 0,
            0.7
        )
        XCTAssertLessThan(
            state?.centerProximity ?? 1,
            0.3
        )
    }

    func testBodyFrameParserAcceptsFutureEquipmentPayload() {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([
                    .number(0),
                    .number(0),
                    .number(0),
                ]),
                "leftHip": .array([
                    .number(-0.1),
                    .number(0),
                    .number(0),
                ]),
                "rightHip": .array([
                    .number(0.1),
                    .number(0),
                    .number(0),
                ]),
                "leftKnee": .array([
                    .number(-0.1),
                    .number(-0.3),
                    .number(0),
                ]),
                "rightKnee": .array([
                    .number(0.1),
                    .number(-0.3),
                    .number(0),
                ]),
                "leftFoot": .array([
                    .number(-0.1),
                    .number(-0.6),
                    .number(0),
                ]),
                "rightFoot": .array([
                    .number(0.1),
                    .number(-0.6),
                    .number(0),
                ]),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftFoot": .string("leftKnee"),
                "rightFoot": .string("rightKnee"),
            ]),
            "indo_board_fiducials_visible": .array([
                .string("MOS:I:RC1"),
                .string("MOS:I:DL1"),
                .string("MOS:I:DR1"),
            ]),
            "indo_board_equipment": .object([
                "sequence": .number(7),
                "device_time_ns": .number(700_000_000),
                "model_id": .string("debug-model"),
                "deck": .object([
                    "left_end": .array([
                        .number(0.2),
                        .number(0.7),
                    ]),
                    "right_end": .array([
                        .number(0.8),
                        .number(0.7),
                    ]),
                    "polygon": .array([]),
                    "confidence": .number(0.9),
                    "provenance": .string("model_estimated"),
                ]),
                "roller": .object([
                    "center": .array([
                        .number(0.5),
                        .number(0.7),
                    ]),
                    "confidence": .number(0.85),
                    "provenance": .string("model_estimated"),
                ]),
            ]),
        ]

        let frame = BodyMovementFrameParser.parseVisionPose(
            payload: payload,
            sessionID: "equipment-test",
            sequence: 7,
            deviceTimeNS: 700_000_000
        )

        XCTAssertNotNil(frame?.indoBoardEquipment)
        XCTAssertEqual(
            frame?.indoBoardEquipment?.modelID,
            "debug-model"
        )
        XCTAssertEqual(
            frame?.indoBoardVisibleFiducials,
            [
                .deckLeft,
                .deckRight,
                .rollerCenter,
            ]
        )
        XCTAssertEqual(
            frame?.indoBoardBalanceState?.centerProximity ?? 0,
            1,
            accuracy: 0.001
        )
    }

    func testBodyFrameSeparatesTrackingFromCoachingEquipment() {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([.number(0), .number(0), .number(0)]),
                "leftHip": .array([.number(-0.1), .number(0), .number(0)]),
                "rightHip": .array([.number(0.1), .number(0), .number(0)]),
                "leftKnee": .array([.number(-0.1), .number(-0.3), .number(0)]),
                "rightKnee": .array([.number(0.1), .number(-0.3), .number(0)]),
                "leftFoot": .array([.number(-0.1), .number(-0.6), .number(0)]),
                "rightFoot": .array([.number(0.1), .number(-0.6), .number(0)]),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftFoot": .string("leftKnee"),
                "rightFoot": .string("rightKnee"),
            ]),
            "indo_board_tracking_equipment": .object([
                "model_id": .string("tracking-only-model"),
                "deck": .object([
                    "left_end": .array([.number(0.2), .number(0.7)]),
                    "right_end": .array([.number(0.8), .number(0.7)]),
                    "confidence": .number(0.91),
                    "provenance": .string("model_estimated"),
                ]),
                "roller": .object([
                    "center": .array([.number(0.56), .number(0.7)]),
                    "confidence": .number(0.89),
                    "provenance": .string("model_estimated"),
                ]),
            ]),
        ]

        let frame = BodyMovementFrameParser.parseVisionPose(
            payload: payload,
            sessionID: "tracking-only",
            sequence: 12,
            deviceTimeNS: 1_200_000_000
        )

        XCTAssertNil(frame?.indoBoardEquipment)
        XCTAssertNil(frame?.indoBoardBalanceState)
        XCTAssertEqual(
            frame?.indoBoardTrackingEquipment?.modelID,
            "tracking-only-model"
        )
        XCTAssertNotNil(
            frame?.indoBoardTrackingBalanceState
        )
    }

    func testEquipmentPayloadInheritsCameraFrameTimestamp() {
        let payload: [String: JSONValue] = [
            "joints_root_relative_m": .object([
                "root": .array([
                    .number(0),
                    .number(0),
                    .number(0),
                ]),
                "leftHip": .array([
                    .number(-0.1),
                    .number(0),
                    .number(0),
                ]),
                "rightHip": .array([
                    .number(0.1),
                    .number(0),
                    .number(0),
                ]),
                "leftKnee": .array([
                    .number(-0.1),
                    .number(-0.3),
                    .number(0),
                ]),
                "rightKnee": .array([
                    .number(0.1),
                    .number(-0.3),
                    .number(0),
                ]),
                "leftFoot": .array([
                    .number(-0.1),
                    .number(-0.6),
                    .number(0),
                ]),
                "rightFoot": .array([
                    .number(0.1),
                    .number(-0.6),
                    .number(0),
                ]),
            ]),
            "joint_parents": .object([
                "root": .null,
                "leftHip": .string("root"),
                "rightHip": .string("root"),
                "leftKnee": .string("leftHip"),
                "rightKnee": .string("rightHip"),
                "leftFoot": .string("leftKnee"),
                "rightFoot": .string("rightKnee"),
            ]),
            "indo_board_equipment": .object([
                "deck": .object([
                    "left_end": .array([
                        .number(0.2),
                        .number(0.7),
                    ]),
                    "right_end": .array([
                        .number(0.8),
                        .number(0.7),
                    ]),
                    "confidence": .number(0.9),
                ]),
                "roller": .object([
                    "center": .array([
                        .number(0.5),
                        .number(0.7),
                    ]),
                    "confidence": .number(0.85),
                ]),
            ]),
        ]

        let frame = BodyMovementFrameParser.parseVisionPose(
            payload: payload,
            sessionID: "timestamp-test",
            sequence: 42,
            deviceTimeNS: 4_200_000_000
        )

        XCTAssertEqual(
            frame?.indoBoardEquipment?.sequence,
            42
        )
        XCTAssertEqual(
            frame?.indoBoardEquipment?.deviceTimeNS,
            4_200_000_000
        )
    }

    func testMissingRollerFailsClosed() {
        let observation = IndoBoardEquipmentObservation(
            sequence: 1,
            deviceTimeNS: 1,
            deck: IndoBoardDeckObservation(
                polygon: [],
                leftEnd: .init(x: 0.2, y: 0.5),
                rightEnd: .init(x: 0.8, y: 0.5),
                confidence: 0.9,
                provenance: .modelEstimated
            ),
            roller: nil
        )

        XCTAssertNil(
            IndoBoardBalanceStateEstimator.estimate(
                from: observation
            )
        )
    }
}
