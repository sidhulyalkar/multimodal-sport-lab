from __future__ import annotations

import json
from pathlib import Path

from motionos.calibration_run import CalibrationRun, RunArtifactReference
from motionos.closure import evaluate_m0_closure


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

    events = tmp_path / "operator-events.jsonl"
    events.write_text("{}\n", encoding="utf-8")

    metadata = tmp_path / "operator-metadata.json"
    metadata.write_text(
        json.dumps(
            {
                "run_id": run_id,
                "protocol_version": protocol,
                "completed_block_ids": ["baseline", "pushes"],
            }
        ),
        encoding="utf-8",
    )

    receipt = tmp_path / "operator-evidence-receipt.json"
    receipt.write_text(
        json.dumps(
            {
                "run_id": run_id,
                "passed": True,
                "sync_cue_labels": ["start", "middle", "end"],
                "failure_notes": failure_notes or [],
            }
        ),
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


def _report(*, insole_state: str = "qualified") -> dict[str, object]:
    states = {
        "watch": "qualified",
        "equipment": "qualified",
        "insoles": insole_state,
        "camera": "qualified",
    }
    return {
        "unresolved_blockers": [],
        "sources": [
            {
                "role": role,
                "qualification": {"state": state},
            }
            for role, state in states.items()
        ],
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
