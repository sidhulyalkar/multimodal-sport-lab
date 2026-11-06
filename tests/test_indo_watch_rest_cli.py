import hashlib
import json

from motionos.cli import main


def test_cli_decodes_watch_events_without_claiming_alignment(tmp_path, capsys):
    session_id = "watch-test-001"
    event = {
        "schema_version": "motionos.m0.v1",
        "session_id": session_id,
        "device_id": "apple-watch",
        "stream": "/experiments/indo/rest_annotation",
        "sequence": 0,
        "device_time_ns": 1000,
        "session_time_ns": None,
        "sync_quality": None,
        "payload": {
            "event_schema": "motionos.indo-rest-events.v1",
            "event_id": "a",
            "event_type": "indo_rest_rest_started",
            "clock_semantics": "watch_monotonic_input_time",
            "run_binding": "unbound",
        },
    }
    data = json.dumps(event).encode() + b"\n"
    path = tmp_path / "watch.jsonl"
    path.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    assert main(
        [
            "indo-watch-rest-events",
            str(path),
            "--watch-session-id",
            session_id,
            "--expected-sha256",
            digest,
        ]
    ) == 0
    output = json.loads(capsys.readouterr().out)
    assert output["source"]["journal_integrity_verified"] is True
    assert output["source"]["camera_alignment_verified"] is False
    assert output["annotations"][0]["run_binding"] == "unbound"
    assert output["incomplete"]["rest_open"] is True
