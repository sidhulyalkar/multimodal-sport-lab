import math
from dataclasses import replace

import pytest

from motionos.indo_board import (
    IndoBoardSample,
    LongitudinalBaseline,
    analyze_indo_board,
    update_longitudinal_baselines,
)


def _session():
    samples = []
    for index in range(80):
        t = index * 0.1
        roll = 1.0 * math.sin(t * 2.0)
        pitch = 0.8 * math.cos(t * 1.5)
        com_x = 0.01 * math.sin(t)
        com_z = 0.008 * math.cos(t)
        if 20 <= index <= 23:
            roll += 12.0
            com_x += 0.07
        samples.append(
            IndoBoardSample(
                time_s=t,
                com_x_m=com_x,
                com_y_m=0.9,
                com_z_m=com_z,
                board_roll_deg=roll,
                board_pitch_deg=pitch,
                left_knee_flexion_deg=28.0 + math.sin(t),
                right_knee_flexion_deg=31.0 + math.sin(t),
                pose_confidence=0.95,
                timing_uncertainty_ms=4.0,
                reprojection_rms_px=0.8,
            )
        )
    return samples


def test_indo_board_report_derives_five_metrics_without_overclaiming():
    report = analyze_indo_board(_session())
    by_id = {metric.metric_id: metric for metric in report.metrics}

    assert report.accepted_sample_count == report.sample_count
    assert len(report.metrics) == 5
    assert by_id["balance_stability_rms_m"].value > 0
    assert by_id["com_excursion_p95_m"].value > 0
    assert by_id["board_control_jerk_rms_deg_s3"].value >= 0
    assert by_id["recovery_latency_median_s"].value is not None
    assert by_id["stance_asymmetry_mean_abs_knee_deg"].value == 3.0
    assert "not a force or muscle-activation measure" in (
        by_id["stance_asymmetry_mean_abs_knee_deg"].definition
    )


def test_quality_gate_rejects_bad_timing_and_low_pose_confidence():
    samples = _session()
    samples[0] = replace(samples[0], pose_confidence=0.1)
    samples[1] = replace(samples[1], timing_uncertainty_ms=100.0)

    report = analyze_indo_board(samples)

    assert report.rejected_sample_count == 2
    assert report.accepted_sample_count == len(samples) - 2


def test_longitudinal_baseline_tracks_mean_variance_and_best():
    report = analyze_indo_board(_session())
    baselines = update_longitudinal_baselines({}, report)
    first = baselines["balance_stability_rms_m"]
    assert first.sample_count == 1

    baseline = LongitudinalBaseline(
        metric_id="recovery_latency_median_s",
        direction="lower_is_better",
    )
    for value in (0.6, 0.4, 0.5):
        baseline.observe(value)

    assert baseline.sample_count == 3
    assert baseline.mean == 0.5
    assert baseline.best_value == 0.4
    assert baseline.sample_standard_deviation == pytest.approx(0.1)
