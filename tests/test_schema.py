from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest


def test_event_round_trip():
    event = SensorEvent(
        session_id="s1",
        device_id="watch",
        stream="/body/watch/imu",
        sequence=3,
        device_time_ns=100,
        session_time_ns=120,
        sync_quality=0.9,
        payload={"ax": 1.0},
    )
    assert SensorEvent.from_json(event.to_json()) == event


def test_manifest_round_trip():
    manifest = SessionManifest(
        session_id="s1",
        created_at_utc="2026-09-21T00:00:00+00:00",
        sport="longboard",
        mode="field",
        athlete_id="athlete",
        devices=(DeviceDescriptor("watch", "watch", "wrist", ("/body/watch/imu",)),),
    )
    assert SessionManifest.from_dict(manifest.to_dict()) == manifest
