from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter


def test_session_bundle_round_trip(tmp_path):
    manifest = SessionManifest(
        session_id="demo",
        created_at_utc="2026-09-21T00:00:00+00:00",
        sport="skateboard",
        mode="field",
        athlete_id="a",
        devices=(DeviceDescriptor("pod", "imu", "board", ("/equipment/imu",)),),
    )
    with SessionWriter(tmp_path, manifest) as writer:
        for sequence in range(3):
            writer.append(
                SensorEvent(
                    "demo",
                    "pod",
                    "/equipment/imu",
                    sequence,
                    sequence * 10,
                    {"ax": sequence},
                    sequence * 10,
                    1.0,
                )
            )
    reader = SessionReader(tmp_path / "demo")
    assert reader.list_streams() == ["/equipment/imu"]
    assert [e.sequence for e in reader.iter_stream("/equipment/imu")] == [0, 1, 2]
