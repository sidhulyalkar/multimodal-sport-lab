import hashlib
import json

import pytest

from motionos.indo_watch_rest_events import WatchRestEvidenceError, extract_watch_rest_events

WATCH_ID = "p0-watch-qualification"
RUN_ID = "m0-indo-qualification"
STREAM = "/experiments/indo/rest_annotation"
SCHEMA = "motionos.indo-rest-events.v1"


def _annotation(kind, seq, **data):
    return {
        "schema_version": "motionos.m0.v1",
        "session_id": WATCH_ID,
        "device_id": "apple-watch",
        "stream": STREAM,
        "sequence": seq,
        "device_time_ns": (123456 + seq * 10) * 1_000_000_000,
        "session_time_ns": None,
        "sync_quality": None,
        "payload": {
            "event_schema": SCHEMA,
            "event_id": f"event-{seq}",
            "event_type": kind,
            "clock_semantics": "watch_monotonic_input_time",
            "run_binding": "bound",
            "linked_run_id": RUN_ID,
            **data,
        },
    }


def _start(seq, bout_id, phase):
    return _annotation(
        "indo_rest_bout_started", seq,
        bout_id=bout_id, phase=phase, skill_id="neutral_balance_hold",
        setup_id="watch_setup_unverified", stance_id="comfortable",
        tracking_mode="watch_only",
    )


def _end(seq, bout_id):
    return _annotation("indo_rest_bout_finished", seq, bout_id=bout_id)


def _write(tmp_path, events):
    file = tmp_path / "watch.jsonl"
    data = b"".join(json.dumps(e).encode() + b"\n" for e in events)
    file.write_bytes(data)
    return file, hashlib.sha256(data).hexdigest()


def _decode(tmp_path, events):
    file, digest = _write(tmp_path, events)
    return extract_watch_rest_events(
        file, watch_session_id=WATCH_ID,
        expected_sha256=digest, expected_run_id=RUN_ID,
    )


def test_offline_watch_session_preserves_rest_and_effort(tmp_path):
    samples = [
        {"schema_version": "motionos.m0.v1", "session_id": WATCH_ID,
         "stream": "/meta/watch", "sequence": 0},
        _start(0, "b1", "reference"),
        _end(1, "b1"),
        _annotation("indo_rest_effort_reported", 2, bout_id="b1", effort_0_10="4"),
        _annotation("indo_rest_rest_started", 3),
        _annotation("indo_rest_rest_finished", 4),
        _start(5, "b2", "post_rest"),
        _end(6, "b2"),
    ]
    result = _decode(tmp_path, samples)
    assert result["source"]["journal_integrity_verified"] is True
    assert result["source"]["camera_alignment_verified"] is False
    assert len(result["bouts"]) == 2
    assert result["bouts"][0]["effort_0_10"] == 4
    assert result["bouts"][0]["metrics"] == {}
    assert result["bouts"][0]["source_verified"] is False
    assert result["bouts"][1]["phase"] == "post_rest"
    assert result["rests"][0]["end_watch_ns"] > result["rests"][0]["start_watch_ns"]
    json.dumps(result)


def test_unbound_event_is_retained_without_implicit_link(tmp_path):
    event = _start(0, "b1", "reference")
    event["payload"].pop("linked_run_id")
    event["payload"]["run_binding"] = "unbound"
    result = _decode(tmp_path, [event, _end(1, "b1")])
    assert result["bouts"][0]["run_binding"] == "unbound"
    assert result["annotations"][0]["linked_run_id"] is None


def test_cryptographic_mismatch_rejected(tmp_path):
    file, digest = _write(tmp_path, [_start(0, "b1", "reference")])
    file.write_bytes(file.read_bytes() + b" ")
    with pytest.raises(WatchRestEvidenceError, match="SHA-256"):
        extract_watch_rest_events(file, watch_session_id=WATCH_ID, expected_sha256=digest)


@pytest.mark.parametrize("mutate", [
    lambda e: e[1].update(sequence=0),
    lambda e: e[1].update(device_time_ns=e[0]["device_time_ns"]),
    lambda e: e[1].update(session_id="foreign"),
    lambda e: e[1]["payload"].update(event_id=e[0]["payload"]["event_id"]),
    lambda e: e[1]["payload"].update(clock_semantics="phone_clock"),
    lambda e: e[1]["payload"].update(linked_run_id="wrong-run"),
    lambda e: e[1]["payload"].update(event_schema="wrong-schema"),
])
def test_corrupt_or_foreign_watch_events_rejected(tmp_path, mutate):
    events = [_start(0, "b1", "reference"), _end(1, "b1")]
    mutate(events)
    with pytest.raises(WatchRestEvidenceError):
        _decode(tmp_path, events)


def test_no_overlapping_bouts(tmp_path):
    events = [_start(0, "b1", "reference"), _start(1, "b2", "late")]
    with pytest.raises(WatchRestEvidenceError, match="overlapping"):
        _decode(tmp_path, events)


def test_post_rest_requires_finished_rest(tmp_path):
    with pytest.raises(WatchRestEvidenceError, match="completed rest"):
        _decode(tmp_path, [_start(0, "b1", "post_rest")])


def test_open_event_preserved_not_falsely_closed(tmp_path):
    result = _decode(tmp_path, [_start(0, "b1", "reference")])
    assert result["incomplete"]["bout_id"] == "b1"
    assert result["bouts"] == []


def test_invalid_effort(tmp_path):
    events = [_start(0, "b1", "reference"), _end(1, "b1"),
              _annotation("indo_rest_effort_reported", 2, bout_id="b1",
                          effort_0_10="12")]
    with pytest.raises(WatchRestEvidenceError, match="effort"):
        _decode(tmp_path, events)


def test_only_watch_events_use_watch_monotonic_timestamps(tmp_path):
    result = _decode(tmp_path, [_start(0, "b1", "reference"), _end(1, "b1")])
    assert "start_s" not in result["bouts"][0]
    assert "end_s" not in result["bouts"][0]
    assert "start_watch_ns" in result["bouts"][0]
    assert "end_watch_ns" in result["bouts"][0]
