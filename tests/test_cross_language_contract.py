from pathlib import Path

from motionos.schema import SensorEvent


FIXTURE = (
    Path(__file__).parents[1]
    / "apple"
    / "MotionOSAppleCapture"
    / "Tests"
    / "MotionOSAppleCaptureTests"
    / "Fixtures"
    / "sensor_event.json"
)


def test_swift_python_fixture_decodes_to_canonical_event():
    event = SensorEvent.from_json(FIXTURE.read_text(encoding="utf-8"))

    assert event.session_id == "fixture-session"
    assert event.device_id == "apple-watch"
    assert event.stream == "/body/watch/imu"
    assert event.sequence == 42
    assert event.device_time_ns == 123_456_789
    assert event.session_time_ns == 123_460_000
    assert event.sync_quality == 0.98
    assert event.payload["az"] == 9.81
