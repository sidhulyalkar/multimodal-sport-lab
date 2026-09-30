import json

import pytest

from motionos.indo_board_quality import build_indo_board_quality_report


def _write(path, document):
    path.write_text(
        json.dumps(document),
        encoding="utf-8",
    )
    return path


def _quality_fixture(tmp_path):
    external = _write(
        tmp_path / "external.json",
        {
            "schema_version": "motionos.external-camera-sync.v1",
            "clock_model": {
                "residual_rms_ms": 4.0,
                "drift_ppm": 12.0,
                "observations_used": 3,
            },
            "external_candidate_count": 5,
        },
    )
    clock = _write(
        tmp_path / "clock.json",
        {
            "schema_version": "motionos.vision-clock-bundle.v1",
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
    )
    skeleton_corr = _write(
        tmp_path / "skeleton-corr.json",
        {
            "schema_version":
                "motionos.multiview-correspondences.v1",
            "pair_count": 2,
            "points": [],
        },
    )
    skeleton_geometry = _write(
        tmp_path / "skeleton-geometry.json",
        {
            "schema_version":
                "motionos.multiview-geometry-report.v1",
            "point_count": 6,
            "reprojection_residual_px": {
                "count": 12,
                "mean": 0.8,
                "median": 0.7,
                "rms": 0.9,
                "p95": 1.3,
                "max": 1.5,
            },
            "ray_disagreement_rms_m": {
                "count": 6,
                "mean": 0.004,
                "median": 0.003,
                "rms": 0.005,
                "p95": 0.008,
                "max": 0.009,
            },
        },
    )
    board_corr = _write(
        tmp_path / "board-corr.json",
        {
            "schema_version":
                "motionos.multiview-correspondences.v1",
            "pair_count": 1,
            "points": [],
        },
    )
    board_geometry = _write(
        tmp_path / "board-geometry.json",
        {
            "schema_version":
                "motionos.multiview-geometry-report.v1",
            "point_count": 4,
            "reprojection_residual_px": {
                "count": 8,
                "mean": 0.5,
                "median": 0.5,
                "rms": 0.6,
                "p95": 0.9,
                "max": 1.0,
            },
            "ray_disagreement_rms_m": {
                "count": 4,
                "mean": 0.002,
                "median": 0.002,
                "rms": 0.002,
                "p95": 0.003,
                "max": 0.003,
            },
        },
    )
    board_pose = _write(
        tmp_path / "board-pose.json",
        {
            "schema_version": "motionos.board-pose-series.v1",
            "pose_count": 2,
            "rejected_frame_count": 1,
            "poses": [
                {
                    "residual_rms_m": 0.002,
                    "residual_max_m": 0.004,
                    "fitted_scale": 1.0,
                },
                {
                    "residual_rms_m": 0.004,
                    "residual_max_m": 0.007,
                    "fitted_scale": 1.01,
                },
            ],
        },
    )
    reconstruction = _write(
        tmp_path / "reconstruction.json",
        {
            "schema_version":
                "motionos.indo-board-reconstruction.v1",
            "sample_count": 3,
            "rejected_sample_count": 1,
            "modeled_mass_coverage": {
                "minimum": 0.78,
                "median": 0.92,
                "maximum": 1.0,
            },
            "rejected_samples": [
                {
                    "reason": "insufficient_com_mass_coverage",
                }
            ],
        },
    )
    metrics = _write(
        tmp_path / "metrics.json",
        {
            "schema_version": "motionos.indo-board-report.v1",
            "session_id": "vision-s1",
            "sample_count": 4,
            "accepted_sample_count": 3,
            "rejected_sample_count": 1,
            "metrics": [
                {
                    "metric_id": "balance_stability_rms_m",
                    "value": 0.02,
                    "unit": "m",
                    "confidence": 0.82,
                    "unavailable_reason": None,
                },
                {
                    "metric_id": "recovery_latency_median_s",
                    "value": None,
                    "unit": "s",
                    "confidence": 0.0,
                    "unavailable_reason":
                        "no complete disturbance/recovery episode was observed",
                },
            ],
        },
    )
    wrist = _write(
        tmp_path / "wrist.json",
        {
            "schema_version":
                "motionos.wrist-acceleration-fusion.v1",
            "wrist_side": "left",
            "sample_count": 2,
            "watch_minus_vision_rms_m_s2": 0.3,
        },
    )
    return {
        "external_sync_path": external,
        "clock_bundle_path": clock,
        "skeleton_correspondences_path": skeleton_corr,
        "skeleton_geometry_path": skeleton_geometry,
        "board_correspondences_path": board_corr,
        "board_geometry_path": board_geometry,
        "board_pose_series_path": board_pose,
        "reconstruction_path": reconstruction,
        "metrics_path": metrics,
        "wrist_fusion_path": wrist,
    }


def test_quality_report_keeps_quality_dimensions_separate(tmp_path):
    inputs = _quality_fixture(tmp_path)
    output = tmp_path / "quality.json"

    report = build_indo_board_quality_report(
        **inputs,
        output_path=output,
    )

    assert report["session_id"] == "vision-s1"
    assert report["summary"]["pose_frame_pairs"] == 2
    assert report["summary"]["board_frame_pairs"] == 1
    assert report["summary"]["metric_accepted_fraction"] == pytest.approx(
        0.75
    )
    assert report["geometry"]["board_pose"]["residual_rms_m"][
        "p95"
    ] == pytest.approx(0.004)
    assert report["reconstruction"]["rejected_reason_counts"] == {
        "insufficient_com_mass_coverage": 1
    }
    assert report["metrics"]["unavailable_metric_ids"] == [
        "recovery_latency_median_s"
    ]
    assert set(report["attention_flags"]) == {
        "metric_quality_gate_rejections_present",
        "reconstruction_rejections_present",
        "board_pose_rejections_present",
        "one_or_more_metrics_unavailable",
    }
    assert output.is_file()


def test_quality_report_rejects_wrong_source_schema(tmp_path):
    inputs = _quality_fixture(tmp_path)
    bad = inputs["wrist_fusion_path"]
    raw = json.loads(bad.read_text(encoding="utf-8"))
    raw["schema_version"] = "wrong.v1"
    bad.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(
        ValueError,
        match="unsupported wrist acceleration fusion schema",
    ):
        build_indo_board_quality_report(
            **inputs,
            output_path=tmp_path / "quality.json",
        )
