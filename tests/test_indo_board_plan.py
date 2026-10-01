import json

import pytest

from motionos.indo_board_plan import (
    build_indo_board_qualification_plan,
    validate_indo_board_qualification_plan,
)
from motionos.provenance import sha256_file


def _fixture(tmp_path):
    rig = tmp_path / "rig.json"
    marker_receipt = tmp_path / "marker-receipt.json"
    layout = tmp_path / "layout.json"
    fusion = tmp_path / "fusion.json"
    spec = tmp_path / "plan-spec.json"

    rig.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-rig-receipt.v1",
                "rig_id": "rig-v1",
                "passed": True,
            }
        ),
        encoding="utf-8",
    )
    marker_receipt.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.aruco-marker-build-receipt.v1",
                "asset_id": "indo-board-markers-v1",
                "dictionary": "DICT_4X4_50",
            }
        ),
        encoding="utf-8",
    )
    layout.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.board-marker-layout.v1",
                "layout_id": "indo-board-markers-v1",
                "marker_dictionary": "DICT_4X4_50",
                "marker_asset_receipt_sha256":
                    sha256_file(marker_receipt),
            }
        ),
        encoding="utf-8",
    )
    fusion.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.wrist-fusion-calibration.v1",
                "recommended_wrist_fusion": {
                    "watch_acceleration_std_m_s2": 0.2,
                    "vision_acceleration_std_m_s2": 0.4,
                    "maximum_acceleration_rate_m_s3": 12.0,
                    "maximum_time_delta_ms": 20.0,
                },
            }
        ),
        encoding="utf-8",
    )

    document = {
        "schema_version":
            "motionos.indo-board-qualification-plan-spec.v1",
        "plan_id": "plan-s1",
        "rig_receipt": rig.name,
        "board_marker_layout": layout.name,
        "board_marker_asset_receipt": marker_receipt.name,
        "wrist_fusion_calibration_receipt": fusion.name,
        "thresholds": {
            "maximum_pose_pair_ms": 10,
            "maximum_marker_pair_ms": 10,
            "minimum_joint_confidence": 0.6,
            "marker_frame_stride": 1,
            "maximum_board_scale_error_fraction": 0.03,
            "maximum_skeleton_board_pair_ms": 20,
            "minimum_modeled_mass_coverage": 0.75,
            "maximum_board_fit_residual_m": 0.03,
            "minimum_pose_confidence": 0.6,
            "maximum_timing_uncertainty_ms": 20,
            "maximum_reprojection_rms_px": 3,
            "minimum_longitudinal_confidence": 0.6,
        },
        "qualification": {
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
            "required_metric_ids": [
                "balance_stability_rms_m",
                "com_excursion_p95_m",
                "board_control_jerk_rms_deg_s3",
                "recovery_latency_median_s",
                "stance_asymmetry_mean_abs_knee_deg",
            ],
        },
        "protocol": {
            "coaching_condition": "feedback_disabled",
            "minimum_sync_landmarks": 3,
        },
    }
    spec.write_text(
        json.dumps(document, indent=2),
        encoding="utf-8",
    )
    return spec, document, rig, layout, marker_receipt, fusion


def test_build_plan_freezes_hashes_and_fusion_parameters(tmp_path):
    spec, document, rig, layout, marker_receipt, fusion = _fixture(
        tmp_path
    )
    output = tmp_path / "plan.json"

    plan = build_indo_board_qualification_plan(spec, output)

    assert plan["plan_id"] == "plan-s1"
    assert plan["frozen_before_scored_capture"] is True
    assert plan["rig_id"] == "rig-v1"
    assert plan["thresholds"] == document["thresholds"]
    assert plan["qualification"] == document["qualification"]
    assert plan["wrist_fusion"] == {
        "watch_acceleration_std_m_s2": 0.2,
        "vision_acceleration_std_m_s2": 0.4,
        "maximum_acceleration_rate_m_s3": 12.0,
        "maximum_time_delta_ms": 20.0,
    }
    assert plan["evidence"]["rig_receipt"]["sha256"] == sha256_file(rig)
    assert plan["evidence"]["board_marker_layout"]["sha256"] == (
        sha256_file(layout)
    )
    assert plan["evidence"]["board_marker_asset_receipt"][
        "sha256"
    ] == sha256_file(marker_receipt)
    assert plan["evidence"]["wrist_fusion_calibration_receipt"][
        "sha256"
    ] == sha256_file(fusion)
    assert validate_indo_board_qualification_plan(output) == plan


def test_plan_builder_rejects_marker_receipt_drift(tmp_path):
    spec, _document, _rig, _layout, marker_receipt, _fusion = _fixture(
        tmp_path
    )
    marker_receipt.write_text(
        marker_receipt.read_text(encoding="utf-8") + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="not bound"):
        build_indo_board_qualification_plan(
            spec,
            tmp_path / "plan.json",
        )


def test_plan_builder_requires_at_least_three_sync_landmarks(tmp_path):
    spec, document, _rig, _layout, _marker, _fusion = _fixture(
        tmp_path
    )
    document["protocol"]["minimum_sync_landmarks"] = 2
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match="at least 3"):
        build_indo_board_qualification_plan(
            spec,
            tmp_path / "plan.json",
        )


def test_plan_builder_rejects_unvalidated_placeholders(tmp_path):
    spec, document, _rig, _layout, _marker, _fusion = _fixture(
        tmp_path
    )
    document["qualification"][
        "maximum_watch_vision_rms_m_s2"
    ] = "REPLACE_ME"
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match="must be numeric"):
        build_indo_board_qualification_plan(
            spec,
            tmp_path / "plan.json",
        )
