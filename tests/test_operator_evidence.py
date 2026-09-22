from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from motionos.operator_evidence import (
    OPERATOR_EVENT_SCHEMA,
    OPERATOR_METADATA_SCHEMA,
    OPERATOR_TIMING_SEMANTICS,
    validate_operator_evidence,
)
from motionos.provenance import sha256_file


def _event(
    *,
    run_id: str,
    sequence: int,
    host_time_ns: int,
    kind: str,
    label: str | None = None,
    message: str | None = None,
) -> dict[str, object]:
    payload: dict[str, str] = {}
    if message is not None:
        payload["message"] = message

    return {
        "schema_version": OPERATOR_EVENT_SCHEMA,
        "run_id": run_id,
        "sequence": sequence,
        "host_monotonic_ns": host_time_ns,
        "wall_clock_utc": f"2026-09-22T21:00:0{sequence}Z",
        "kind": kind,
        "block_id": None,
        "label": label,
        "payload": payload,
        "timing_semantics": OPERATOR_TIMING_SEMANTICS,
    }


def _write_bundle(
    root: Path,
    *,
    mutate_events: Callable[[list[dict[str, object]]], None] | None = None,
    metadata_updates: dict[str, object] | None = None,
) -> Path:
    root.mkdir(parents=True)
    run_id = "m0-longboard-fixture"

    events = [
        _event(
            run_id=run_id,
            sequence=0,
            host_time_ns=100,
            kind="run_created",
        ),
        _event(
            run_id=run_id,
            sequence=1,
            host_time_ns=200,
            kind="run_started",
        ),
        _event(
            run_id=run_id,
            sequence=2,
            host_time_ns=300,
            kind="sync_cue_annotation",
            label="start",
        ),
        _event(
            run_id=run_id,
            sequence=3,
            host_time_ns=400,
            kind="failure_note",
            label="operator-observed failure",
            message="camera mount moved 2 mm? check footage",
        ),
        _event(
            run_id=run_id,
            sequence=4,
            host_time_ns=500,
            kind="sync_cue_annotation",
            label="middle",
        ),
        _event(
            run_id=run_id,
            sequence=5,
            host_time_ns=600,
            kind="sync_cue_annotation",
            label="end",
        ),
        _event(
            run_id=run_id,
            sequence=6,
            host_time_ns=700,
            kind="run_sealed",
        ),
    ]

    if mutate_events is not None:
        mutate_events(events)

    journal = root / "operator-events.jsonl"
    journal.write_text(
        "".join(json.dumps(event, sort_keys=True) + "\n" for event in events),
        encoding="utf-8",
    )

    metadata: dict[str, object] = {
        "schema_version": OPERATOR_METADATA_SCHEMA,
        "event_schema_version": OPERATOR_EVENT_SCHEMA,
        "run_id": run_id,
        "protocol_version": "motionos.longboard-calibration.v1",
        "event_count": len(events),
        "operator_events_sha256": sha256_file(journal),
        "timing_semantics": OPERATOR_TIMING_SEMANTICS,
    }
    if metadata_updates:
        metadata.update(metadata_updates)

    (root / "operator-metadata.json").write_text(
        json.dumps(metadata, sort_keys=True),
        encoding="utf-8",
    )
    return root


def test_operator_evidence_passes_and_preserves_failure_note(tmp_path):
    root = _write_bundle(tmp_path / "operator")

    receipt = validate_operator_evidence(root)

    assert receipt.passed is True
    assert receipt.event_count == 7
    assert receipt.first_host_monotonic_ns == 100
    assert receipt.last_host_monotonic_ns == 700
    assert receipt.sync_cue_labels == ("start", "middle", "end")
    assert receipt.failure_notes == (
        "camera mount moved 2 mm? check footage",
    )
    assert receipt.non_monotonic_events == 0
    assert receipt.missing_sequence_events == 0
    assert receipt.metadata_errors == ()
    assert len(receipt.source_evidence_sha256["operator_events_jsonl"]) == 64


def test_operator_journal_hash_tampering_fails_closed(tmp_path):
    root = _write_bundle(tmp_path / "operator")
    journal = root / "operator-events.jsonl"
    journal.write_text(
        journal.read_text(encoding="utf-8") + "\n",
        encoding="utf-8",
    )

    receipt = validate_operator_evidence(root)

    assert receipt.passed is False
    assert "metadata.operator_events_sha256" in receipt.metadata_errors


def test_operator_sequence_gap_fails(tmp_path):
    def mutate(events):
        events[3]["sequence"] = 9

    root = _write_bundle(
        tmp_path / "operator",
        mutate_events=mutate,
    )

    receipt = validate_operator_evidence(root)

    assert receipt.passed is False
    assert receipt.missing_sequence_events > 0


def test_operator_non_monotonic_annotation_time_fails(tmp_path):
    def mutate(events):
        events[4]["host_monotonic_ns"] = 250

    root = _write_bundle(
        tmp_path / "operator",
        mutate_events=mutate,
    )

    receipt = validate_operator_evidence(root)

    assert receipt.passed is False
    assert receipt.non_monotonic_events == 1


def test_operator_run_identity_mismatch_fails(tmp_path):
    def mutate(events):
        events[2]["run_id"] = "other-run"

    root = _write_bundle(
        tmp_path / "operator",
        mutate_events=mutate,
    )

    receipt = validate_operator_evidence(root)

    assert receipt.passed is False
    assert receipt.run_id_errors == 1


def test_operator_timing_semantics_mismatch_fails(tmp_path):
    def mutate(events):
        events[2]["timing_semantics"] = "host_time_is_sync_authority"

    root = _write_bundle(
        tmp_path / "operator",
        mutate_events=mutate,
    )

    receipt = validate_operator_evidence(root)

    assert receipt.passed is False
    assert receipt.timing_semantics_errors == 1
