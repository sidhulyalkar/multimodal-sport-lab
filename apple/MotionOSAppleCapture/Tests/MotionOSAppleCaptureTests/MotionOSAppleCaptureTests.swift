import XCTest
@testable import MotionOSAppleCapture

final class MotionOSAppleCaptureTests: XCTestCase {
    func testClockMapping() {
        let model = ClockModel(slope: 1.00001, interceptNS: 1000, residualRMSNS: 0)
        XCTAssertEqual(model.sessionTime(deviceTimeNS: 1_000_000), 1_001_010)
    }

    func testEnvelopeJSONRoundTrip() throws {
        let event = SensorEnvelope(
            sessionID: "s1",
            deviceID: "watch",
            stream: "/body/watch/imu",
            sequence: 1,
            deviceTimeNS: 100,
            payload: ["ax": .number(1.2)]
        )
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(
            try JSONDecoder().decode(SensorEnvelope.self, from: data),
            event
        )
    }
}
