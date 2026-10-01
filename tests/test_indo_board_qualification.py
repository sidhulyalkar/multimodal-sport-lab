import json

import pytest

from motionos.indo_board_qualification import (
    FIRST_FIVE_METRIC_IDS,
    build_indo_board_qualification_receipt,
    validate_qualification_contract,
)


def _quality_document():
    return {
        "schema_version": "motionos.indo-board-quality-report.v1",
        "session_id": "vision-s1",
        "summary": {
            "pose_frame_pairs": 240,
            "board_frame_pairs": 220,
            "board_pose_count": 210,
            "board_pose_rejected_count": 10,
            "reconstruction_sample_count": 200,
            "metric_input_sample_count": 200,
            "metric_accepted_sample_count": 190,
            "metric_rejected_sample_count": 10,
            "metric_accepted_fraction": 0.95,
            "wrist_fusion_sample_count": 180,
        },
        "timing": {
            "external_physical_landmark_clock": {
                "residual_rms_ms": 4.0,
                "drift_ppm": 12.0,
                "observations_used": 3,
                "candidate_peak_count": 5,
            },
            "canonical_watch_clock_models": {
                "watch_to_host": {
                    "residual_rms_ms": 1.0,
                    "drift_ppm": 2.0,
                    "observations_used": 3,
                },
                "iphone_camera_to_watch": {
                    "residual_rms_ms": 1.5,
                    "drift_ppm": 3.0,
                    "observations_used": 4,
                },
                "action4_to_watch": {
                    "residual_rms_ms": 4.5,
                    "drift_ppm": 14.0,
                    "observations_used": 3,
                },
            },
        },
        "geometry": {
            "skeleton": {
                "reprojection_residual_px": {
                    "rms": 0.9,
                },
                "ray_disagreement_rms_m": {
                    "rms": 0.005,
                },
            },
            "board_markers": {
                "reprojection_residual_px": {
                    "rms": 0.6,
                },
                "ray_disagreement_rms_m": {
                    "rms": 0.002,
                },
            },
            "board_pose": {
                "residual_rms_m": {
                    "p95": 0.004,
                },
                "absolute_scale_error_fraction": {
                    "p95": 0.01,
                },
            },
        },
        "reconstruction": {
            "modeled_mass_coverage": {
                "minimum": 0.8,
                "median": 0.92,
                "maximum": 1.0,
            },
            "rejected_reason_counts": {
                "insufficient_com_mass_coverage": 5,
            },
        },
        "metrics": {
            "estimates": [
                {
                    "metric_id": metric_id,
                    "value": 0.1,
                    "unit": "fixture",
                    "confidence": 0.9,
                    "available": True,
                    "unavailable_reason": None,
                }
                for metric_id in FIRST_FIVE_METRIC_IDS
            ],
            "unavailable_metric_ids": [],
        },
        "cross_modal_consistency": {
            "wrist_side": "left",
            "watch_minus_vision_rms_m_s2": 0.3,
        },
        "attention_flags": [],
        "claim_boundary": "",
    }


def _qualification():
    return {
        "minimum_pose_frame_pairs": 100,
        "minimum_board_frame_pairs": 100,
        "minimum_board_pose_count": 100,
        "minimum_metric_accepted_samples": 100,
        "minimum_metric_accepted_fraction": 0.8,
        "maximum_external_clock_residual_ms": 10.0,
        "maximum_iphone_clock_residual_ms": 5.0,
        "maximum_action4_clock_residual_ms": 10.0,
        "maximum_skeleton_reprojection_rms_px": 2.0,
        "maximum_board_reprojection_rms_px": 2.0,
        "maximum_board_pose_residual_p95_m": 0.01,
        "maximum_board_pose_scale_error_p95_fraction": 0.02,
        "maximum_board_pose_rejected_fraction": 0.1,
        "maximum_reconstruction_rejected_fraction": 0.1,
        "maximum_watch_vision_rms_m_s2": 1.0,
        "required_metric_ids": list(FIRST_FIVE_METRIC_IDS),
    }


def test_qualification_passes_only_when_all_frozen_gates_pass(tmp_path):
    quality = tmp_path / "quality.json"
    output = tmp_path / "qualification.json"
    quality.write_text(
        json.dumps(_quality_document()),
        encoding="utf-8",
    )

    receipt = build_indo_board_qualification_receipt(
        quality,
        _qualification(),
        output,
    )

    assert receipt["passed"] is True
    assert receipt["failed_gate_ids"] == []
    assert receipt["longitudinal_update_permitted"] is True
    assert all(gate["passed"] for gate in receipt["gates"])
    assert output.is_file()


def test_unavailable_required_metric_fails_qualification(tmp_path):
    document = _quality_document()
    missing_id = "recovery_latency_median_s"
    document["metrics"]["unavailable_metric_ids"] = [missing_id]
    for item in document["metrics"]["estimates"]:
        if item["metric_id"] == missing_id:
            item["value"] = None
            item["available"] = False

    quality = tmp_path / "quality.json"
    quality.write_text(json.dumps(document), encoding="utf-8")

    receipt = build_indo_board_qualification_receipt(
        quality,
        _qualification(),
        tmp_path / "qualification.json",
    )

    assert receipt["passed"] is False
    assert "required_metrics_available" in receipt["failed_gate_ids"]
    assert receipt["longitudinal_update_permitted"] is False


def test_excessive_clock_residual_fails_without_composite_score(tmp_path):
    document = _quality_document()
    document["timing"]["external_physical_landmark_clock"][
        "residual_rms_ms"
    ] = 25.0
    quality = tmp_path / "quality.json"
    quality.write_text(json.dumps(document), encoding="utf-8")

    receipt = build_indo_board_qualification_receipt(
        quality,
        _qualification(),
        tmp_path / "qualification.json",
    )

    assert receipt["passed"] is False
    assert "external_clock_residual_rms_ms" in receipt["failed_gate_ids"]
    assert "score" not in receipt


def test_qualification_contract_rejects_placeholders():
    contract = _qualification()
    contract["maximum_watch_vision_rms_m_s2"] = "REPLACE_ME"

    with pytest.raises(ValueError, match="must be numeric"):
        validate_qualification_contract(contract)
