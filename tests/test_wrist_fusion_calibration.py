import json
import math

import pytest

import motionos.wrist_fusion_calibration as calibration
from motionos.wrist_fusion_calibration import (
    calibrate_wrist_fusion,
    validate_wrist_fusion_calibration_spec,
)


def _write_inputs(tmp_path):
    geometry = tmp_path / "geometry.json"
    correspondences = tmp_path / "correspondences.json"
    watch = tmp_path / "watch.jsonl"
    spec = tmp_path / "spec.json"

    geometry.write_text('{"fixture":"geometry"}\n', encoding="utf-8")
    correspondences.write_text(
        '{"fixture":"correspondences"}\n',
        encoding="utf-8",
    )
    watch.write_text("fixture-watch\n", encoding="utf-8")
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.wrist-fusion-calibration-spec.v1",
                "stationary_window_s": [0.0, 0.9],
                "dynamic_window_s": [2.0, 5.5],
                "maximum_time_delta_ms": 5.0,
                "minimum_stationary_pairs": 8,
                "minimum_dynamic_pairs": 20,
                "jerk_percentile": 0.95,
                "jerk_margin_factor": 1.25,
                "wrist_side": "left",
            }
        ),
        encoding="utf-8",
    )
    return geometry, correspondences, watch, spec


def _series():
    vision = []
    watch = []
    for index in range(60):
        time_ns = index * 100_000_000
        if index < 10:
            vision_value = 0.10 + 0.02 * (index % 2)
            watch_value = 0.05 + 0.01 * (index % 2)
        else:
            phase = index * 0.37
            vision_value = 1.0 + 0.45 * math.sin(phase)
            watch_value = 1.05 + 0.40 * math.sin(phase + 0.08)

        vision.append(
            {
                "time_ns": time_ns,
                "value": vision_value,
                "timing_uncertainty_ns": 1_000_000,
            }
        )
        watch.append(
            {
                "time_ns": time_ns,
                "value": watch_value,
            }
        )
    return tuple(vision), tuple(watch)


def test_calibration_derives_empirical_fusion_parameters(
    tmp_path,
    monkeypatch,
):
    geometry, correspondences, watch_path, spec = _write_inputs(
        tmp_path
    )
    vision, watch = _series()

    monkeypatch.setattr(
        calibration,
        "load_skeleton_frames",
        lambda *args: (object(),),
    )
    monkeypatch.setattr(
        calibration,
        "load_watch_events",
        lambda *args: (),
    )
    monkeypatch.setattr(
        calibration,
        "vision_wrist_acceleration",
        lambda *args, **kwargs: vision,
    )
    monkeypatch.setattr(
        calibration,
        "watch_acceleration_magnitude",
        lambda *args: watch,
    )

    output = tmp_path / "calibration.json"
    receipt = calibrate_wrist_fusion(
        geometry,
        correspondences,
        watch_path,
        spec,
        output,
    )

    assert receipt["wrist_side"] == "left"
    assert receipt["stationary_window"]["pair_count"] == 10
    assert receipt["dynamic_window"]["pair_count"] >= 20
    assert receipt["stationary_window"][
        "watch_acceleration_rms_m_s2"
    ] == pytest.approx(
        math.sqrt((5 * 0.05**2 + 5 * 0.06**2) / 10)
    )
    assert receipt["stationary_window"][
        "vision_acceleration_rms_m_s2"
    ] == pytest.approx(
        math.sqrt((5 * 0.10**2 + 5 * 0.12**2) / 10)
    )

    recommended = receipt["recommended_wrist_fusion"]
    assert recommended["watch_acceleration_std_m_s2"] > 0
    assert recommended["vision_acceleration_std_m_s2"] > 0
    assert recommended["maximum_acceleration_rate_m_s3"] > 0
    assert recommended["maximum_time_delta_ms"] == 5.0
    assert receipt["dynamic_window"][
        "observed_percentile_m_s3"
    ] * 1.25 == pytest.approx(
        recommended["maximum_acceleration_rate_m_s3"]
    )
    assert output.is_file()


def test_calibration_rejects_overlapping_windows(tmp_path):
    _geometry, _correspondences, _watch, spec = _write_inputs(
        tmp_path
    )
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["dynamic_window_s"] = [0.5, 2.0]
    spec.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="must not overlap"):
        validate_wrist_fusion_calibration_spec(spec)


def test_calibration_spec_requires_nonshrinking_jerk_margin(tmp_path):
    _geometry, _correspondences, _watch, spec = _write_inputs(
        tmp_path
    )
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["jerk_margin_factor"] = 0.9
    spec.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="at least 1.0"):
        validate_wrist_fusion_calibration_spec(spec)


def test_calibration_rejects_insufficient_stationary_pairs(
    tmp_path,
    monkeypatch,
):
    geometry, correspondences, watch_path, spec = _write_inputs(
        tmp_path
    )
    vision, watch = _series()
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["minimum_stationary_pairs"] = 20
    spec.write_text(json.dumps(raw), encoding="utf-8")

    monkeypatch.setattr(
        calibration,
        "load_skeleton_frames",
        lambda *args: (object(),),
    )
    monkeypatch.setattr(
        calibration,
        "load_watch_events",
        lambda *args: (),
    )
    monkeypatch.setattr(
        calibration,
        "vision_wrist_acceleration",
        lambda *args, **kwargs: vision,
    )
    monkeypatch.setattr(
        calibration,
        "watch_acceleration_magnitude",
        lambda *args: watch,
    )

    with pytest.raises(
        ValueError,
        match="stationary calibration window has fewer paired samples",
    ):
        calibrate_wrist_fusion(
            geometry,
            correspondences,
            watch_path,
            spec,
            tmp_path / "out.json",
        )
