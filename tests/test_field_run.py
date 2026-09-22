from __future__ import annotations

import json
from pathlib import Path

import pytest

from motionos.field_run import build_field_run_receipt
from motionos.provenance import sha256_file


BLOCKS = [
    "baseline",
    "pushes",
    "straight-glide",
    "left-carves",
    "right-carves",
    "front-load",
    "rear-load",
    "foot-reposition",
    "braking",
    "perturbations",
]


def _event(
    sequence: int,
    event_type: str,
    *,
    label: str | None = None,
    block_id: str | None = None,
    host_time_ns: int | None = None,
) -> dict[str, object]:
    return {
        "schema_version": "motionos.field-run.v1",
        "run_id": "m0-longboard-fixture",
        "sequence": sequence,
        "event_type": event_type,
        "host_monotonic_ns": (
            host_time_ns
            if host_time_ns is not None
            else 1_000_000_000 + sequence * 10_000_000
        ),
        "wall_time_utc": (
            f"2026-09-22T21:00:{sequence % 60:02d}+00:00"
        ),
        "label": label,
        "block_id": block_id,
        "state": {
            "watch": "running",
            "equipment_pod": "recording",
            "camera": "recording",
            "insoles": "armed_external",
        },
        "timing_authority": "operator_annotation_only",
    }


def _write_bundle(
    directory: Path,
    *,
    include_end_marker: bool = True,
    failure: str | None = None,
    bad_sequence: bool = False,
    non_monotonic: bool = False,
) -> Path:
    directory.mkdir(parents=True)

    rows: list[dict[str, object]] = []
    rows.append(_event(0, "run_started", label="start run"))
    sequence = 1

    rows.append(_event(sequence, "sync_marker", label="start"))
    sequence += 1

    for block in BLOCKS:
        rows.append(
            _event(
                sequence,
                "movement_block_started",
                label=block,
                block_id=block,
            )
        )
        sequence += 1
        rows.append(
            _event(
                sequence,
                "movement_block_completed",
                label=block,
                block_id=block,
            )
        )
        sequence += 1

        if block == "right-carves":
            rows.append(
                _event(sequence, "sync_marker", label="middle")
            )
            sequence += 1

    if include_end_marker:
        rows.append(
            _event(sequence, "sync_marker", label="end")
        )
        sequence += 1

    if failure is not None:
        rows.append(
            _event(
                sequence,
                "failure_marker",
                label=failure,
            )
        )
        sequence += 1

    rows.append(
        _event(
            sequence,
            "run_stopped",
            label="stop run",
        )
    )

    if bad_sequence:
        rows[-1]["sequence"] = int(rows[-1]["sequence"]) + 2

    if non_monotonic:
        rows[-1]["host_monotonic_ns"] = int(
            rows[-2]["host_monotonic_ns"]
        )

    ledger = directory / "field-run.jsonl"
    ledger.write_text(
        "".join(
            json.dumps(row, sort_keys=True) + "\n"
            for row in rows
        ),
        encoding="utf-8",
    )

    event_counts: dict[str, int] = {}
    for row in rows:
        event_type = str(row["event_type"])
        event_counts[event_type] = event_counts.get(event_type, 0) + 1

    metadata = directory / "field-run-metadata.json"
    metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.field-run.v1",
                "run_id": "m0-longboard-fixture",
                "protocol_version":
                    "motionos.longboard-calibration.v1",
                "planned_movement_blocks": BLOCKS,
                "event_counts": event_counts,
                "timing_authority":
                    "operator_annotation_only",
                "ledger_sha256": sha256_file(ledger),
            }
        ),
        encoding="utf-8",
    )
    return directory


def test_field_run_receipt_passes_complete_protocol(tmp_path):
    directory = _write_bundle(tmp_path / "field-run")

    receipt = build_field_run_receipt(directory)

    assert receipt.integrity_passed is True
    assert receipt.protocol_complete is True
    assert receipt.clean_run is True
    assert receipt.sync_markers == ("start", "middle", "end")
    assert receipt.completed_blocks == tuple(BLOCKS)
    assert receipt.incomplete_blocks == ()
    assert receipt.failure_markers == ()
    assert len(receipt.source_evidence_sha256["field_run_jsonl"]) == 64
    assert (
        len(
            receipt.source_evidence_sha256[
                "field_run_metadata_json"
            ]
        )
        == 64
    )


def test_failure_marker_is_preserved_without_corrupting_ledger(tmp_path):
    directory = _write_bundle(
        tmp_path / "field-run",
        failure="camera mount bumped during braking",
    )

    receipt = build_field_run_receipt(directory)

    assert receipt.integrity_passed is True
    assert receipt.protocol_complete is True
    assert receipt.clean_run is False
    assert receipt.failure_markers == (
        "camera mount bumped during braking",
    )


def test_missing_end_sync_marker_blocks_protocol_completion(tmp_path):
    directory = _write_bundle(
        tmp_path / "field-run",
        include_end_marker=False,
    )

    receipt = build_field_run_receipt(directory)

    assert receipt.integrity_passed is True
    assert receipt.protocol_complete is False
    assert receipt.clean_run is False
    assert receipt.sync_markers == ("start", "middle")


def test_sequence_error_blocks_integrity(tmp_path):
    directory = _write_bundle(
        tmp_path / "field-run",
        bad_sequence=True,
    )

    receipt = build_field_run_receipt(directory)

    assert receipt.sequence_errors == 1
    assert receipt.integrity_passed is False


def test_non_monotonic_operator_time_blocks_integrity(tmp_path):
    directory = _write_bundle(
        tmp_path / "field-run",
        non_monotonic=True,
    )

    receipt = build_field_run_receipt(directory)

    assert receipt.non_monotonic_host_times == 1
    assert receipt.integrity_passed is False


def test_metadata_hash_tampering_is_detected(tmp_path):
    directory = _write_bundle(tmp_path / "field-run")
    ledger = directory / "field-run.jsonl"
    ledger.write_text(
        ledger.read_text(encoding="utf-8") + "\n",
        encoding="utf-8",
    )

    receipt = build_field_run_receipt(directory)

    assert "ledger_sha256" in receipt.metadata_mismatches
    assert receipt.integrity_passed is False


def test_operator_annotations_never_emit_clock_observations(tmp_path):
    directory = _write_bundle(tmp_path / "field-run")
    receipt = build_field_run_receipt(directory)

    payload = receipt.to_dict()
    serialized = json.dumps(payload, sort_keys=True)

    assert "device_time_ns" not in serialized
    assert "session_time_ns" not in serialized
    assert "clock_model" not in serialized
    assert "operator_annotation_only" not in serialized


def test_invalid_wall_time_is_rejected(tmp_path):
    directory = _write_bundle(tmp_path / "field-run")
    ledger = directory / "field-run.jsonl"
    rows = [
        json.loads(line)
        for line in ledger.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    rows[0]["wall_time_utc"] = "not-a-time"
    ledger.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )

    metadata = directory / "field-run-metadata.json"
    raw = json.loads(metadata.read_text(encoding="utf-8"))
    raw["ledger_sha256"] = sha256_file(ledger)
    metadata.write_text(json.dumps(raw), encoding="utf-8")

    receipt = build_field_run_receipt(directory)

    assert receipt.invalid_wall_times == 1
    assert receipt.integrity_passed is False
