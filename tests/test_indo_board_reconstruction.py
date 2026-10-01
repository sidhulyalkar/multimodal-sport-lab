import json

import pytest

from motionos.indo_board_reconstruction import (
    build_indo_board_samples,
    estimate_center_of_mass,
)


def _joints(offset: float = 0.0):
    return {
        "neck": (0.0 + offset, 1.55, 0.0),
        "nose": (0.0 + offset, 1.68, 0.0),
        "left_shoulder": (-0.20 + offset, 1.48, 0.0),
        "right_shoulder": (0.20 + offset, 1.48, 0.0),
        "left_elbow": (-0.32 + offset, 1.20, 0.0),
        "right_elbow": (0.32 + offset, 1.20, 0.0),
        "left_wrist": (-0.36 + offset, 0.98, 0.0),
        "right_wrist": (0.36 + offset, 0.98, 0.0),
        "left_hip": (-0.12 + offset, 0.98, 0.0),
        "right_hip": (0.12 + offset, 0.98, 0.0),
        "left_knee": (-0.12 + offset, 0.55, 0.02),
        "right_knee": (0.12 + offset, 0.55, -0.02),
        "left_ankle": (-0.12 + offset, 0.08, 0.04),
        "right_ankle": (0.12 + offset, 0.08, -0.04),
    }


def test_segment_com_model_reports_full_mass_coverage():
    estimate = estimate_center_of_mass(_joints())

    assert estimate.modeled_mass_coverage == pytest.approx(1.0)
    assert estimate.position_m[1] > 0.6
    assert estimate.position_m[1] < 1.2
    assert estimate.position_m[0] == pytest.approx(0.0, abs=1e-9)


def test_reconstruction_builds_metric_samples_from_geometry(tmp_path):
    geometry_points = []
    correspondence_points = []
    board_poses = []

    for frame_index in range(4):
        time_ns = 1_000_000_000 + frame_index * 100_000_000
        joints = _joints(offset=0.01 * frame_index)
        for name, position in joints.items():
            point_id = f"{name}-ref-{time_ns}"
            geometry_points.append(
                {
                    "point_id": point_id,
                    "reference_time_ns": time_ns,
                    "world_position_m": list(position),
                    "mean_reprojection_residual_px": 0.7,
                    "timing": {
                        "iphone-rear": {
                            "clock_predictive_std_ms": 2.0,
                        },
                        "dji-action4": {
                            "clock_predictive_std_ms": 3.0,
                        },
                    },
                }
            )
            correspondence_points.append(
                {
                    "point_id": point_id,
                    "reference_time_ns": time_ns,
                    "observations": {
                        "iphone-rear": {"joint_confidence": 0.95},
                        "dji-action4": {"joint_confidence": 0.90},
                    },
                }
            )

        board_poses.append(
            {
                "reference_time_ns": time_ns + 2_000_000,
                "roll_deg": float(frame_index),
                "pitch_deg": 0.5 * frame_index,
                "residual_rms_m": 0.005,
            }
        )

    geometry = tmp_path / "skeleton-geometry.json"
    correspondences = tmp_path / "skeleton-correspondences.json"
    board = tmp_path / "board-poses.json"
    geometry.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-geometry-report.v1",
                "points": geometry_points,
            }
        ),
        encoding="utf-8",
    )
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "points": correspondence_points,
            }
        ),
        encoding="utf-8",
    )
    board.write_text(
        json.dumps(
            {
                "schema_version": "motionos.board-pose-series.v1",
                "poses": board_poses,
            }
        ),
        encoding="utf-8",
    )

    samples, diagnostics = build_indo_board_samples(
        geometry,
        correspondences,
        board,
    )

    assert len(samples) == 4
    assert diagnostics["rejected_sample_count"] == 0
    assert samples[0].timing_uncertainty_ms == pytest.approx(3.0)
    assert samples[-1].com_x_m > samples[0].com_x_m
    assert samples[0].left_knee_flexion_deg is not None
    assert samples[0].right_knee_flexion_deg is not None
