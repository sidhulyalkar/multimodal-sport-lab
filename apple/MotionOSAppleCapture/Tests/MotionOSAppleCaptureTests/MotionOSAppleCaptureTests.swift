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
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(raw.contains("\\"session_id\\":\\"s1\\""))
        XCTAssertTrue(raw.contains("\\"device_time_ns\\":100"))
        XCTAssertFalse(raw.contains("sessionID"))
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
