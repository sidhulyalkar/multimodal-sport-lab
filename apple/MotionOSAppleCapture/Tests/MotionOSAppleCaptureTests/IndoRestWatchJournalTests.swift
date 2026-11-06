import XCTest
@testable import MotionOSAppleCapture

final class IndoRestWatchJournalTests: XCTestCase {
    private let context = IndoRestPilotContext(
        skillID: "neutral_balance_hold",
        setupID: "watch_setup_unverified",
        stanceID: "comfortable",
        trackingMode: "watch_only"
    )

    func testWatchEnvelopeCarriesIndependentClockAndRunBinding() throws {
        var reducer = IndoRestPilotRecorder()
        let action = try reducer.accept(
            .boutStarted(id: "b1", phase: .reference, context: context)
        )
        let event = IndoRestWatchJournal.envelope(
            sessionID: "watch-123",
            runID: "run-123",
            sequence: 0,
            deviceTimeNS: 1000,
            eventID: "event-1",
            event: action
        )
        XCTAssertEqual(event.stream, "/experiments/indo/rest_annotation")
        XCTAssertEqual(event.sessionID, "watch-123")
        XCTAssertEqual(event.sequence, 0)
        XCTAssertEqual(event.deviceTimeNS, 1000)
        XCTAssertNil(event.sessionTimeNS)
        XCTAssertNil(event.syncQuality)
        XCTAssertEqual(event.payload["linked_run_id"], .string("run-123"))
        XCTAssertEqual(event.payload["run_binding"], .string("bound"))
        XCTAssertEqual(event.payload["event_id"], .string("event-1"))
        XCTAssertEqual(event.payload["event_type"], .string("indo_rest_bout_started"))
        XCTAssertEqual(event.payload["clock_semantics"], .string("watch_monotonic_input_time"))
        XCTAssertEqual(event.payload["tracking_mode"], .string("watch_only"))
    }

    func testUnboundAnnotationDoesNotInventPhoneRun() throws {
        var reducer = IndoRestPilotRecorder()
        let action = try reducer.accept(.restStarted)
        let event = IndoRestWatchJournal.envelope(
            sessionID: "watch-123",
            runID: nil,
            sequence: 0,
            deviceTimeNS: 10,
            eventID: "event-2",
            event: action
        )
        XCTAssertNil(event.payload["linked_run_id"])
        XCTAssertEqual(event.payload["run_binding"], .string("unbound"))
        XCTAssertEqual(event.payload["event_schema"], .string("motionos.indo-rest-events.v1"))
        XCTAssertNil(event.sessionTimeNS)
    }
}
