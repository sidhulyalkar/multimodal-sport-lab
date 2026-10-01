import json

import motionos.indo_board_status as status_module
from motionos.indo_board_status import build_indo_board_status
from motionos.provenance import sha256_file


def _write(path, payload):
    path.write_text(
        json.dumps(payload),
        encoding="utf-8",
    )
    return path


def _plan(tmp_path):
    path = _write(
        tmp_path / "plan.json",
        {
            "schema_version":
                "motionos.indo-board-qualification-plan.v1",
            "plan_id": "plan-s1",
            "frozen_before_scored_capture": True,
            "protocol": {
                "coaching_condition": "feedback_disabled",
                "minimum_sync_landmarks": 3,
            },
            "evidence": {
                "rig_receipt": {"sha256": "a" * 64},
                "board_marker_layout": {"sha256": "b" * 64},
                "board_marker_asset_receipt": {"sha256": "c" * 64},
                "wrist_fusion_calibration_receipt":
                    {"sha256": "d" * 64},
            },
            "thresholds": {},
            "wrist_fusion": {},
            "qualification": {},
        },
    )
    return path


def _fake_plan_validator(path):
    return json.loads(path.read_text(encoding="utf-8"))


def test_status_plan_only_points_to_scored_capture(
    tmp_path,
    monkeypatch,
):
    plan = _plan(tmp_path)
    monkeypatch.setattr(
        status_module,
        "validate_indo_board_qualification_plan",
        _fake_plan_validator,
    )

    status = build_indo_board_status(plan)

    assert status["plan"]["valid"] is True
    assert status["pipeline_preflight"]["provided"] is False
    assert status["results"]["processed"] is False
    assert "Capture the scored" in status["next_action"]


def test_status_valid_pipeline_points_to_processing(
    tmp_path,
    monkeypatch,
):
    plan = _plan(tmp_path)
    pipeline = _write(
        tmp_path / "pipeline.json",
        {
            "schema_version":
                "motionos.indo-board-pipeline-spec.v1",
            "qualification_plan": plan.name,
        },
    )
    monkeypatch.setattr(
        status_module,
        "validate_indo_board_qualification_plan",
        _fake_plan_validator,
    )
    monkeypatch.setattr(
        status_module,
        "validate_indo_board_pipeline_spec",
        lambda path: json.loads(path.read_text(encoding="utf-8")),
    )

    status = build_indo_board_status(
        plan,
        pipeline_spec_path=pipeline,
    )

    assert status["pipeline_preflight"]["valid"] is True
    assert status["pipeline_preflight"][
        "qualification_plan_matches"
    ] is True
    assert "process-indo-board-vision" in status["next_action"]


def test_status_processed_failure_surfaces_failed_gates(
    tmp_path,
    monkeypatch,
):
    plan = _plan(tmp_path)
    plan_hash = sha256_file(plan)
    pipeline = _write(
        tmp_path / "pipeline.json",
        {
            "schema_version":
                "motionos.indo-board-pipeline-spec.v1",
            "qualification_plan": plan.name,
        },
    )
    results = tmp_path / "results"
    results.mkdir()

    _write(
        results / "indo-board-pipeline-receipt.json",
        {
            "schema_version":
                "motionos.indo-board-pipeline-receipt.v1",
            "session_id": "scored-s1",
            "qualification_plan_sha256": plan_hash,
            "qualification_passed": False,
            "longitudinal_updated": False,
            "qualification_failed_gate_ids": [
                "external_clock_residual_rms_ms",
            ],
            "attention_flags": [
                "metric_quality_gate_rejections_present",
            ],
            "quality_summary": {
                "metric_accepted_fraction": 0.75,
            },
        },
    )
    _write(
        results / "indo-board-quality-report.json",
        {
            "schema_version":
                "motionos.indo-board-quality-report.v1",
        },
    )
    _write(
        results / "indo-board-qualification-receipt.json",
        {
            "schema_version":
                "motionos.indo-board-qualification-receipt.v1",
        },
    )

    monkeypatch.setattr(
        status_module,
        "validate_indo_board_qualification_plan",
        _fake_plan_validator,
    )
    monkeypatch.setattr(
        status_module,
        "validate_indo_board_pipeline_spec",
        lambda path: json.loads(path.read_text(encoding="utf-8")),
    )

    status = build_indo_board_status(
        plan,
        pipeline_spec_path=pipeline,
        results_directory=results,
    )

    assert status["results"]["processed"] is True
    assert status["results"]["qualification_passed"] is False
    assert status["results"]["longitudinal_updated"] is False
    assert status["results"]["failed_gate_ids"] == [
        "external_clock_residual_rms_ms"
    ]
    assert "did not qualify" in status["next_action"]


def test_status_rejects_pipeline_bound_to_different_plan(
    tmp_path,
    monkeypatch,
):
    plan = _plan(tmp_path)
    other_plan = _write(
        tmp_path / "other-plan.json",
        {"different": True},
    )
    pipeline = _write(
        tmp_path / "pipeline.json",
        {
            "schema_version":
                "motionos.indo-board-pipeline-spec.v1",
            "qualification_plan": other_plan.name,
        },
    )
    monkeypatch.setattr(
        status_module,
        "validate_indo_board_qualification_plan",
        _fake_plan_validator,
    )

    status = build_indo_board_status(
        plan,
        pipeline_spec_path=pipeline,
    )

    assert status["pipeline_preflight"]["valid"] is False
    assert "does not reference" in status["pipeline_preflight"]["error"]
