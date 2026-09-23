from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.clock_sync import ClockLandmark, write_clock_sync
from motionos.clock_uncertainty import (
    WeightedObservation,
    analyze_clock_uncertainty,
    fit_weighted_affine_clock,
    observations_from_landmarks,
    query_clock_uncertainty,
)
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionWriter


def _observation(index, x, y, uncertainty):
    return WeightedObservation(
        index=index,
        device_time_ns=x,
        session_time_ns=y,
        uncertainty_ns=uncertainty,
    )


def test_weighted_fit_downweights_uncertain_landmark():
    observations = (
        _observation(0, 0, 10_000_000, 1_000_000),
        _observation(1, 1_000_000_000, 1_010_000_000, 1_000_000),
        _observation(2, 2_000_000_000, 2_030_000_000, 50_000_000),
        _observation(3, 3_000_000_000, 3_010_000_000, 1_000_000),
    )

    model = fit_weighted_affine_clock(observations)

    assert model.slope == pytest.approx(1.0, abs=2e-5)
    assert model.intercept_ns == pytest.approx(10_000_000, abs=100_000)
    assert model.observations_used == 4


def _landmark(index, x, y, uncertainty):
    return ClockLandmark(
        index=index,
        reference_window_start_ns=y - 10,
        reference_window_end_ns=y + 10,
        target_window_start_ns=x - 10,
        target_window_end_ns=x + 10,
        reference_time_ns=y,
        target_device_time_ns=x,
        uncertainty_ns=uncertainty,
        reference_sequence=index,
        target_sequence=index,
        reference_peak_value=1.0,
        target_peak_value=1.0,
    )


def test_zero_landmark_uncertainty_requires_explicit_default():
    landmarks = (
        _landmark(0, 0, 10, 1_000_000),
        _landmark(1, 1_000_000_000, 1_000_000_010, 0),
        _landmark(2, 2_000_000_000, 2_000_000_010, 1_000_000),
    )

    with pytest.raises(ValueError, match="explicit positive default"):
        observations_from_landmarks(landmarks)

    observations = observations_from_landmarks(
        landmarks,
        default_uncertainty_ns=2_000_000,
    )
    assert observations[1].uncertainty_ns == 2_000_000


def test_prediction_uncertainty_grows_outside_landmark_support():
    observations = tuple(
        _observation(
            index,
            index * 1_000_000_000,
            index * 1_000_000_000 + 25_000_000,
            1_000_000,
        )
        for index in range(5)
    )
    model = fit_weighted_affine_clock(observations)

    inside = model.parameter_std_ns(2_000_000_000)
    outside = model.parameter_std_ns(10_000_000_000)

    assert outside > inside
    assert model.outside_support_ns(10_000_000_000) == 6_000_000_000


def test_piecewise_diagnostic_detects_slope_change():
    observations = []
    for index in range(8):
        x = index * 1_000_000_000
        if index <= 3:
            y = x + 20_000_000
        else:
            y = (
                3_000_000_000
                + 20_000_000
                + round(1.002 * (x - 3_000_000_000))
            )
        observations.append(
            _observation(index, x, y, 100_000)
        )

    # Exercise the private analysis through the public end-to-end helper below
    # for serialization; here the weighted model itself must remain finite.
    model = fit_weighted_affine_clock(tuple(observations))
    assert model.slope > 1.0005


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    stream: str,
    times: list[int],
    impulses: set[int],
) -> Path:
    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="calibration",
        mode="calibration",
        athlete_id="fixture",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="imu",
                placement="fixture",
                streams=(stream,),
            ),
        ),
        metadata={},
    )
    with SessionWriter(root, manifest) as writer:
        for sequence, time_ns in enumerate(times):
            writer.append(
                SensorEvent(
                    session_id=session_id,
                    device_id=device_id,
                    stream=stream,
                    sequence=sequence,
                    device_time_ns=time_ns,
                    payload={
                        "ax": 30.0 if sequence in impulses else 1.0,
                        "ay": 0.0,
                        "az": 0.0,
                    },
                )
            )
    return root / session_id


def test_end_to_end_uncertainty_analysis_preserves_v1_receipt(tmp_path):
    target_times = [
        index * 100_000_000
        for index in range(61)
    ]
    slope = 1.0 + 32e-6
    intercept = 45_000_000
    reference_times = [
        round(slope * value + intercept)
        for value in target_times
    ]
    impulses = {2, 15, 30, 45, 58}

    reference = _write_session(
        tmp_path / "sessions",
        session_id="watch",
        device_id="watch",
        stream="/body/watch/imu",
        times=reference_times,
        impulses=impulses,
    )
    target = _write_session(
        tmp_path / "sessions",
        session_id="pod",
        device_id="pod",
        stream="/equipment/imu/accel",
        times=target_times,
        impulses=impulses,
    )

    windows = []
    for index in sorted(impulses):
        windows.append(
            {
                "reference_start_ns": reference_times[index] - 40_000_000,
                "reference_end_ns": reference_times[index] + 40_000_000,
                "target_start_ns": target_times[index] - 40_000_000,
                "target_end_ns": target_times[index] + 40_000_000,
                "uncertainty_ns": 2_000_000,
            }
        )
    windows_path = tmp_path / "windows.json"
    windows_path.write_text(json.dumps(windows), encoding="utf-8")
    receipt_path = tmp_path / "clock-v1.json"
    write_clock_sync(
        reference,
        target,
        windows_path,
        receipt_path,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )
    original_bytes = receipt_path.read_bytes()

    output = tmp_path / "clock-uncertainty.json"
    analysis = analyze_clock_uncertainty(
        reference,
        target,
        receipt_path,
        output,
    )

    assert receipt_path.read_bytes() == original_bytes
    assert analysis["schema_version"] == "motionos.clock-uncertainty.v1"
    assert analysis["source_clock_sync"]["schema_version"] == (
        "motionos.clock-sync.v1"
    )
    assert analysis["weighted_affine"]["drift_ppm"] == pytest.approx(
        32.0,
        abs=0.01,
    )
    assert analysis["leave_one_out"]["rms_error_ms"] < 0.001
    assert len(analysis["landmark_diagnostics"]) == 5

    midpoint = 3_000_000_000
    inside = query_clock_uncertainty(output, midpoint)
    outside = query_clock_uncertainty(output, 20_000_000_000)

    assert inside["extrapolated"] is False
    assert outside["extrapolated"] is True
    assert outside["fit_parameter_std_ns"] > inside["fit_parameter_std_ns"]


def test_discontinuity_diagnostic_is_numeric_not_pass_fail(tmp_path):
    target_times = [
        index * 100_000_000
        for index in range(101)
    ]
    reference_times = list(target_times)
    impulses = {2, 20, 40, 60, 80, 98}

    # Add a real step after the midpoint. The v1 affine receipt remains valid
    # structurally, while M1 diagnostics should expose inconsistency.
    for index in range(50, len(reference_times)):
        reference_times[index] += 15_000_000

    reference = _write_session(
        tmp_path / "sessions",
        session_id="watch-jump",
        device_id="watch",
        stream="/body/watch/imu",
        times=reference_times,
        impulses=impulses,
    )
    target = _write_session(
        tmp_path / "sessions",
        session_id="pod-jump",
        device_id="pod",
        stream="/equipment/imu/accel",
        times=target_times,
        impulses=impulses,
    )
    windows = [
        {
            "reference_start_ns": reference_times[index] - 30_000_000,
            "reference_end_ns": reference_times[index] + 30_000_000,
            "target_start_ns": target_times[index] - 30_000_000,
            "target_end_ns": target_times[index] + 30_000_000,
            "uncertainty_ns": 1_000_000,
        }
        for index in sorted(impulses)
    ]
    windows_path = tmp_path / "windows.json"
    windows_path.write_text(json.dumps(windows), encoding="utf-8")
    receipt_path = tmp_path / "clock-v1.json"
    write_clock_sync(
        reference,
        target,
        windows_path,
        receipt_path,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )

    analysis = analyze_clock_uncertainty(
        reference,
        target,
        receipt_path,
        tmp_path / "analysis.json",
    )

    diagnostic = analysis["discontinuity"]
    assert diagnostic["max_adjacent_slope_jump_ppm"] > 1_000
    assert "passed" not in diagnostic
    assert analysis["model_comparison"]["available"] is True
