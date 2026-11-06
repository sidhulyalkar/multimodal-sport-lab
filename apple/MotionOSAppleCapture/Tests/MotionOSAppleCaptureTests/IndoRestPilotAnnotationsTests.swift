import XCTest
@testable import MotionOSAppleCapture

final class IndoRestPilotAnnotationsTests: XCTestCase {
    private let context = IndoRestPilotContext(
        skillID: "neutral_balance_hold",
        setupID: "tripod-a",
        stanceID: "comfortable",
        trackingMode: "board_roller"
    )

    func testValidSequenceEmitsParsableOperatorKinds() throws {
        var state = IndoRestPilotRecorder()
        let start = try state.accept(
            .boutStarted(id: "b1", phase: .reference, context: context)
        )
        XCTAssertEqual(start.kind, "indo_rest_bout_started")
        XCTAssertEqual(start.payload["event_schema"], "motionos.indo-rest-events.v1")
        XCTAssertEqual(start.payload["stance_id"], "comfortable")
        XCTAssertEqual(state.activeBoutID, "b1")
        _ = try state.accept(.boutFinished(id: "b1"))
        let effort = try state.accept(.effortReported(boutID: "b1", rating: 7))
        XCTAssertEqual(effort.payload["effort_0_10"], "7")
        _ = try state.accept(.restStarted)
        XCTAssertTrue(state.isResting)
        _ = try state.accept(.restFinished)
        let post = try state.accept(
            .boutStarted(id: "b2", phase: .postRest, context: context)
        )
        XCTAssertEqual(post.payload["phase"], "post_rest")
        XCTAssertEqual(state.completedRestCount, 1)
    }

    func testNoOverlappingBoutOrRest() throws {
        var state = IndoRestPilotRecorder()
        _ = try state.accept(
            .boutStarted(id: "b1", phase: .reference, context: context)
        )
        XCTAssertThrowsError(try state.accept(.restStarted))
        XCTAssertThrowsError(
            try state.accept(.boutStarted(id: "b2", phase: .late, context: context))
        )
        _ = try state.accept(.boutFinished(id: "b1"))
        _ = try state.accept(.restStarted)
        XCTAssertThrowsError(try state.accept(.restStarted))
        XCTAssertThrowsError(try state.accept(.boutFinished(id: "b1")))
    }

    func testNoPostRestWithoutRest() {
        var state = IndoRestPilotRecorder()
        XCTAssertThrowsError(
            try state.accept(
                .boutStarted(id: "b1", phase: .postRest, context: context)
            )
        )
    }

    func testDuplicateIdentifiersAndEffortRejected() throws {
        var state = IndoRestPilotRecorder()
        _ = try state.accept(
            .boutStarted(id: "b1", phase: .reference, context: context)
        )
        _ = try state.accept(.boutFinished(id: "b1"))
        XCTAssertThrowsError(
            try state.accept(
                .boutStarted(id: "b1", phase: .late, context: context)
            )
        )
        _ = try state.accept(.effortReported(boutID: "b1", rating: 3))
        XCTAssertThrowsError(
            try state.accept(.effortReported(boutID: "b1", rating: 4))
        )
        XCTAssertThrowsError(
            try state.accept(.effortReported(boutID: "b1", rating: 11))
        )
    }

    func testMissingContextRejected() {
        var state = IndoRestPilotRecorder()
        let missing = IndoRestPilotContext(
            skillID: "neutral_balance_hold",
            setupID: "",
            stanceID: "comfortable",
            trackingMode: "board_roller"
        )
        XCTAssertThrowsError(
            try state.accept(
                .boutStarted(id: "b1", phase: .reference, context: missing)
            )
        )
        XCTAssertNil(state.activeBoutID)
    }

    func testFailedTransitionLeavesStateUnchanged() throws {
        var state = IndoRestPilotRecorder()
        XCTAssertThrowsError(try state.accept(.restFinished))
        XCTAssertFalse(state.isResting)
        _ = try state.accept(.restStarted)
        XCTAssertThrowsError(
            try state.accept(
                .boutStarted(id: "b1", phase: .late, context: context)
            )
        )
        XCTAssertNil(state.activeBoutID)
        XCTAssertTrue(state.isResting)
    }
}
