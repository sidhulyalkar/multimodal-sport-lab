import XCTest
@testable import MotionOSAppleCapture

final class MotionOSAppleCaptureTests: XCTestCase {
    func testClockMapping() {
        let model = ClockModel(slope: 1.00001, interceptNS: 1000, residualRMSNS: 0)
        XCTAssertEqual(model.sessionTime(deviceTimeNS: 1_000_000), 1_001_010)
    }

    func testMonotonicClockAdvances() {
        let a = MonotonicClock.nowNS()
        let b = MonotonicClock.nowNS()
        XCTAssertGreaterThanOrEqual(b, a)
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["session_id"] as? String, "s1")
        XCTAssertEqual(object["device_id"] as? String, "watch")
        XCTAssertEqual(object["device_time_ns"] as? Int, 100)
        XCTAssertNil(object["sessionID"])
        XCTAssertNil(object["deviceTimeNS"])

        XCTAssertEqual(
            try JSONDecoder().decode(SensorEnvelope.self, from: data),
            event
        )
    }

    func testCanonicalFixtureDecodesInSwift() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "sensor_event",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: url)
        let event = try JSONDecoder().decode(SensorEnvelope.self, from: data)
        XCTAssertEqual(event.sessionID, "fixture-session")
        XCTAssertEqual(event.deviceID, "apple-watch")
        XCTAssertEqual(event.sequence, 42)
        XCTAssertEqual(event.sessionTimeNS, 123_460_000)
        XCTAssertEqual(event.syncQuality, 0.98)
    }
}
