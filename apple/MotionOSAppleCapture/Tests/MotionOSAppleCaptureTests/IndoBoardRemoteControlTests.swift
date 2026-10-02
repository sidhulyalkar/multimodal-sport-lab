import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardRemoteControlTests: XCTestCase {
    func testCommandRoundTrip() {
        let command = IndoBoardRemoteCommand(
            requestID: "req-1",
            action: .startSession,
            sentAtUnixSeconds: 123.5
        )

        let parsed = IndoBoardRemoteCommand(message: command.message)
        XCTAssertEqual(parsed, command)
    }

    func testAcknowledgmentRoundTrip() {
        let acknowledgment = IndoBoardRemoteCommandAck(
            requestID: "req-2",
            action: .finishSession,
            accepted: false,
            messageText: "No session is recording.",
            receivedAtUnixSeconds: 456.0
        )

        let parsed = IndoBoardRemoteCommandAck(
            message: acknowledgment.message
        )
        XCTAssertEqual(parsed, acknowledgment)
    }

    func testStatusRoundTripAndDeliveryEquivalence() {
        let status = IndoBoardRemoteStatus(
            cameraPhase: "ready",
            framingState: "ready",
            framingScore: 100,
            framingTitle: "Camera is ready",
            framingInstruction: "Start when ready.",
            sessionPhase: "idle",
            sessionInstruction: nil,
            startReady: true,
            startBlocker: nil,
            phoneBatteryFraction: 0.75,
            phoneStorageGB: 42.5,
            sentAtUnixSeconds: 100
        )

        guard let parsed = IndoBoardRemoteStatus(message: status.message)
        else {
            XCTFail("Expected a valid remote status")
            return
        }

        XCTAssertEqual(parsed, status)

        let later = IndoBoardRemoteStatus(
            cameraPhase: status.cameraPhase,
            framingState: status.framingState,
            framingScore: status.framingScore,
            framingTitle: status.framingTitle,
            framingInstruction: status.framingInstruction,
            sessionPhase: status.sessionPhase,
            sessionInstruction: status.sessionInstruction,
            startReady: status.startReady,
            startBlocker: status.startBlocker,
            phoneBatteryFraction: status.phoneBatteryFraction,
            phoneStorageGB: status.phoneStorageGB,
            sentAtUnixSeconds: 999
        )

        XCTAssertTrue(status.equivalentForDelivery(to: later))
    }
}
