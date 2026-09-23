from __future__ import annotations

import hashlib
import json
from pathlib import Path

from motionos.calibration_run import CalibrationRun, RunArtifactReference
from motionos.closure import evaluate_m0_closure
from motionos.operator_evidence import (
    OPERATOR_EVENT_SCHEMA,
    OPERATOR_METADATA_SCHEMA,
    OPERATOR_TIMING_SEMANTICS,
    validate_operator_evidence,
)


def _artifact(path: str, kind: str) -> RunArtifactReference:
    return RunArtifactReference(
        path=path,
        sha256="0" * 64,
        kind=kind,
    )


def _run_with_operator_evidence(
    tmp_path: Path,
    *,
    failure_notes: list[str] | None = None,
    run_failure_modes: tuple[str, ...] = (),
) -> tuple[Path, CalibrationRun]:
    run_id = "m0-longboard-test"
    protocol = "motionos.longboard-calibration.v1"

    journal_events = [
        {
            "schema_version": OPERATOR_EVENT_SCHEMA,
            "run_id": run_id,
            "sequence": 0,
            "host_monotonic_ns": 100,
            "timing_semantics": OPERATOR_TIMING_SEMANTICS,
            "kind": "run_created",
            "label": "test run",
            "payload": {},
        },
        *[
            {
                "schema_version": OPERATOR_EVENT_SCHEMA,
                "run_id": run_id,
                "sequence": index,
                "host_monotonic_ns": index * 100,
                "timing_semantics": OPERATOR_TIMING_SEMANTICS,
                "kind": "sync_cue_annotation",
                "label": label,
                "payload": {},
            }
            for index, label in enumerate(
                ("start", "middle", "end"),
                start=1,
            )
        ],
    ]
    for note in failure_notes or []:
        journal_events.append(
            {
                "schema_version": OPERATOR_EVENT_SCHEMA,
                "run_id": run_id,
                "sequence": len(journal_events),
                "host_monotonic_ns": len(journal_events) * 100,
                "timing_semantics": OPERATOR_TIMING_SEMANTICS,
                "kind": "failure_note",
                "label": "operator-observed failure",
                "payload": {"message": note},
            }
        )

    events = tmp_path / "operator-events.jsonl"
    events.write_text(
        "".join(
            json.dumps(event, sort_keys=True) + "\n"
            for event in journal_events
        ),
        encoding="utf-8",
    )
    journal_hash = hashlib.sha256(events.read_bytes()).hexdigest()

    metadata = tmp_path / "operator-metadata.json"
    metadata.write_text(
        json.dumps(
            {
                "schema_version": OPERATOR_METADATA_SCHEMA,
                "event_schema_version": OPERATOR_EVENT_SCHEMA,
                "timing_semantics": OPERATOR_TIMING_SEMANTICS,
                "run_id": run_id,
                "protocol_version": protocol,
                "event_count": len(journal_events),
                "operator_events_sha256": journal_hash,
                "completed_block_ids": ["baseline", "pushes"],
            }
        ),
        encoding="utf-8",
    )

    receipt = tmp_path / "operator-evidence-receipt.json"
    receipt.write_text(
        json.dumps(validate_operator_evidence(tmp_path).to_dict()),
        encoding="utf-8",
    )

    run = CalibrationRun(
        run_id=run_id,
        sport="longboard",
        protocol_version=protocol,
        calibration_bundle=_artifact("calibration.json", "calibration_bundle"),
        profiles=(),
        artifacts=(
            _artifact(events.name, "operator_events"),
            _artifact(metadata.name, "operator_metadata"),
            _artifact(receipt.name, "operator_evidence_receipt"),
            _artifact("p2-physical-spec.json", "p2_qualification_spec"),
        ),
        movement_blocks=(
            {"id": "baseline", "label": "quiet stance"},
            {"id": "pushes", "label": "pushes"},
        ),
        sync_landmarks=(
            {"label": "start"},
            {"label": "middle"},
            {"label": "end"},
        ),
        notes=(),
        failure_modes=run_failure_modes,
        reference_role="watch",
        reference_session_id="watch-session",
        source_roles=("watch", "equipment", "insoles", "camera"),
    )
    return tmp_path / "run.json", run


def _report(
    *,
    insole_state: str = "qualified",
    bad_watch_bundle: bool = False,
) -> dict[str, object]:
    states = {
        "watch": "qualified",
        "equipment": "qualified",
        "insoles": insole_state,
        "camera": "qualified",
    }
    protocols = {
        "watch": "P0",
        "equipment": "P1",
        "insoles": "P2",
        "camera": "P5A-camera",
    }
    sources: list[dict[str, object]] = []
    for role, state in states.items():
        session_id = f"{role}-session"
        bundle_sha256 = role[0] * 64
        if role == "insoles":
            receipt = {
                "protocol": "P2",
                "passed": state == "qualified",
                "field_session_id": session_id,
                "session_bundle_sha256": {
                    "field": bundle_sha256,
                },
                "qualification_spec_sha256": "0" * 64,
            }
        else:
            receipt = {
                "protocol": protocols[role],
                "session_id": session_id,
                "bundle_sha256": (
                    "0" * 64
                    if role == "watch" and bad_watch_bundle
                    else bundle_sha256
                ),
            }
        sources.append(
            {
                "role": role,
                "session_id": session_id,
                "bundle_sha256": bundle_sha256,
                "qualification": {
                    "state": state,
                    "receipt": receipt,
                },
            }
        )
    return {
        "unresolved_blockers": [],
        "sources": sources,
    }


def test_m0_closure_passes_only_complete_physical_chain(
    tmp_path,
    monkeypatch,
):
    run_path, run = _run_with_operator_evidence(tmp_path)

    monkeypatch.setattr(
        "motionos.closure.load_calibration_run",
        lambda *_args, **_kwargs: run,
    )
    monkeypatch.setattr(
        "motionos.closure.build_calibration_report",
        lambda *_args, **_kwargs: _report(),
    )

    receipt = evaluate_m0_closure(run_path)

    assert receipt.passed is True
    assert receipt.unresolved_blockers == ()
    assert receipt.operator_evidence["state"] == "qualified"
    assert receipt.p2_qualification_spec["state"] == "qualified"
    assert receipt.body_model["state"] == "not_requested"


def test_m0_closure_rejects_capture_only_source_receipt(
    tmp_path,
    monkeypatch,
):
    run_path, run = _run_with_operator_evidence(tmp_path)

    monkeypatch.setattr(
        "motionos.closure.load_calibration_run",
        lambda *_args, **_kwargs: run,
    )
    monkeypatch.setattr(
        "motionos.closure.build_calibration_report",
        lambda *_args, **_kwargs: _report(insole_state="capture_only"),
    )

    receipt = evaluate_m0_closure(run_path)

    assert receipt.passed is False
    assert receipt.source_qualification["insoles"] == "capture_only"
    assert any(
        "insoles: full physical qualification required" in blocker
        for blocker in receipt.unresolved_blockers
    )


def test_m0_closure_requires_operator_failures_in_run_manifest(
    tmp_path,
    monkeypatch,
):
    run_path, run = _run_with_operator_evidence(
        tmp_path,
        failure_notes=["camera mount moved"],
    )

    monkeypatch.setattr(
        "motionos.closure.load_calibration_run",
        lambda *_args, **_kwargs: run,
    )
    monkeypatch.setattr(
        "motionos.closure.build_calibration_report",
        lambda *_args, **_kwargs: _report(),
    )

    receipt = evaluate_m0_closure(run_path)

    assert receipt.passed is False
    assert any(
        "failure notes not propagated" in blocker
        for blocker in receipt.unresolved_blockers
    )


def test_m0_closure_rejects_receipt_from_different_source_bundle(
    tmp_path,
    monkeypatch,
):
    run_path, run = _run_with_operator_evidence(tmp_path)

    monkeypatch.setattr(
        "motionos.closure.load_calibration_run",
        lambda *_args, **_kwargs: run,
    )
    monkeypatch.setattr(
        "motionos.closure.build_calibration_report",
        lambda *_args, **_kwargs: _report(bad_watch_bundle=True),
    )

    receipt = evaluate_m0_closure(run_path)

    assert receipt.passed is False
    assert any(
        "watch: qualification receipt bundle hash does not match source"
        in blocker
        for blocker in receipt.unresolved_blockers
    )
