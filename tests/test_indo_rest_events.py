import hashlib
import json

import pytest

from motionos.indo_rest_events import OperatorEvidenceError, extract_indo_rest_events

RUN_ID = "m0-indo-test-run"
SCHEMA = "motionos.operator-events.v1"
PILOT = "motionos.indo-rest-events.v1"
KINDS = [
    "indo_rest_bout_started",
    "indo_rest_bout_finished",
    "indo_rest_rest_started",
    "indo_rest_rest_finished",
    "indo_rest_effort_reported",
]


def _event(kind, i, payload=None):
    return {
        "schema_version": SCHEMA,
        "run_id": RUN_ID,
        "sequence": i,
        "host_monotonic_ns": (100 + 15 * i) * 1_000_000_000,
        "wall_clock_utc": "2026-11-05T22:00:00Z",
        "kind": kind,
        "block_id": None,
        "label": None,
        "payload": payload or {},
        "timing_semantics": "annotation_only_not_sync_authority",
    }


def _marker(kind, i, **payload):
    payload = {"event_schema": PILOT, "event_id": f"event-{i}", **payload}
    return _event(kind, i, payload)


def _start(bout_id, phase, i):
    return _marker(
        KINDS[0], i, bout_id=bout_id, phase=phase, skill_id="neutral_balance_hold",
        setup_id="tripod-a", stance_id="comfortable", tracking_mode="board_roller",
    )


def _end(bout_id, i):
    return _marker(KINDS[1], i, bout_id=bout_id)


def _write(tmp_path, events):
    path = tmp_path / "operator.jsonl"
    data = b"".join(json.dumps(event).encode() + b"\n" for event in events)
    path.write_bytes(data)
    return path, hashlib.sha256(data).hexdigest()


def _read(tmp_path, events):
    path, digest = _write(tmp_path, events)
    return extract_indo_rest_events(path, run_id=RUN_ID, expected_sha256=digest)


def test_round_trip_operator_journal_and_rest(tmp_path):
    events = [
        _event("run_armed", 0),
        _event("run_started", 1),
        _start("b1", "reference", 2),
        _end("b1", 3),
        _marker(KINDS[4], 4, bout_id="b1", effort_0_10="3"),
        _marker(KINDS[2], 5),
        _marker(KINDS[3], 6),
        _start("b2", "post_rest", 7),
        _end("b2", 8),
        _event("run_sealed", 9),
    ]
    report = _read(tmp_path, events)
    assert report["source"]["run_sealed"] is True
    assert report["bouts"][0]["start_s"] == pytest.approx(15)
    assert report["bouts"][0]["end_s"] == pytest.approx(30)
    assert report["bouts"][0]["effort_0_10"] == 3
    assert report["rests"][0] == {"start_s": 60.0, "end_s": 75.0}
    assert report["bouts"][1]["phase"] == "post_rest"
    assert report["bouts"][1]["source_verified"] is False
    assert report["bouts"][1]["metrics"] == {}
    assert report["incomplete"] == {"bout_id": None, "rest_open": False}


def test_modified_journal_rejected(tmp_path):
    events = [_event("run_started", 0), _event("run_sealed", 1)]
    path, digest = _write(tmp_path, events)
    path.write_bytes(path.read_bytes() + b" ")
    with pytest.raises(OperatorEvidenceError, match="digest mismatch"):
        extract_indo_rest_events(path, run_id=RUN_ID, expected_sha256=digest)


@pytest.mark.parametrize("modify", [
    lambda e: e[1].update(sequence=0),
    lambda e: e[1].update(host_monotonic_ns=1),
    lambda e: e[1].update(run_id="wrong-run"),
    lambda e: e[1].update(timing_semantics="camera-synced"),
    lambda e: e[1].update(schema_version="unknown"),
])
def test_corrupt_event_contract_rejected(tmp_path, modify):
    events = [_event("run_started", 0), _start("b", "reference", 1)]
    modify(events)
    with pytest.raises(OperatorEvidenceError):
        _read(tmp_path, events)


def test_bout_rest_overlap_rejected(tmp_path):
    events = [_event("run_started", 0), _start("b", "reference", 1),
              _marker(KINDS[2], 2)]
    with pytest.raises(OperatorEvidenceError, match="overlap"):
        _read(tmp_path, events)


def test_post_rest_requires_completed_rest(tmp_path):
    events = [_event("run_started", 0), _start("b", "post_rest", 1)]
    with pytest.raises(OperatorEvidenceError, match="completed rest"):
        _read(tmp_path, events)


def test_duplicate_pilot_event_id_rejected(tmp_path):
    events = [_event("run_started", 0), _start("b", "reference", 1),
              _end("b", 2)]
    events[-1]["payload"]["event_id"] = events[-2]["payload"]["event_id"]
    with pytest.raises(OperatorEvidenceError, match="duplicate pilot"):
        _read(tmp_path, events)


def test_open_session_preserves_incomplete_bout(tmp_path):
    events = [_event("run_started", 0), _start("b", "reference", 1)]
    report = _read(tmp_path, events)
    assert report["source"]["run_sealed"] is False
    assert report["bouts"] == []
    assert report["incomplete"]["bout_id"] == "b"


def test_effort_during_active_bout_rejected(tmp_path):
    events = [
        _event("run_started", 0), _start("b1", "reference", 1),
        _end("b1", 2), _start("b2", "late", 3),
        _marker(KINDS[4], 4, bout_id="b1", effort_0_10="7"),
    ]
    with pytest.raises(OperatorEvidenceError):
        _read(tmp_path, events)


@pytest.mark.parametrize("value", ["11", "-1", "1.5", "nan", ""])
def test_invalid_effort_rejected(tmp_path, value):
    events = [
        _event("run_started", 0), _start("b", "reference", 1),
        _end("b", 2), _marker(KINDS[4], 3, bout_id="b", effort_0_10=value),
    ]
    with pytest.raises(OperatorEvidenceError, match="effort"):
        _read(tmp_path, events)


def test_started_and_ended_bout_have_positive_duration(tmp_path):
    events = [_event("run_started", 0), _start("b", "reference", 1), _end("b", 2)]
    events[2]["host_monotonic_ns"] = events[1]["host_monotonic_ns"]
    with pytest.raises(OperatorEvidenceError, match="nonpositive"):
        _read(tmp_path, events)


def test_pilot_event_after_seal_rejected(tmp_path):
    events = [_event("run_started", 0), _event("run_sealed", 1),
              _start("b", "reference", 2)]
    with pytest.raises(OperatorEvidenceError):
        _read(tmp_path, events)
