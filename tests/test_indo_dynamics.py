import math

import pytest

from motionos.indo_board_state import BoardFrameState
from motionos.indo_dynamics import DynamicsConfig, analyze_indo_dynamics


def frame(t, x, confidence=0.95):
    return BoardFrameState(float(t), 0.0, float(x), 0.0, confidence)


def cfg(**overrides):
    return DynamicsConfig(**{**dict(min_frames=2, min_exposure_s=0.5), **overrides})


def test_time_fraction_uses_elapsed_time_not_frame_count():
    frames = [frame(0, 0), frame(0.1, 0), frame(0.2, 0), frame(0.4, 0.9), frame(0.6, 0.9)]
    result = analyze_indo_dynamics(frames, config=cfg(max_gap_s=0.25))
    assert result["status"] == "descriptive_only"
    assert result["metrics"]["center_time_fraction"] == pytest.approx(0.5)
    assert result["metrics"]["edge_time_fraction"] == pytest.approx(0.5)


def test_gap_censors_active_recovery_and_blocks_false_settled_event():
    frames = [frame(0, 0), frame(0.1, 0.5), frame(0.2, 0.4), frame(1.2, 0.0), frame(1.3, 0.0)]
    result = analyze_indo_dynamics(frames, config=cfg(min_coverage=0, min_exposure_s=0.2))
    assert result["quality"]["contiguous_segment_count"] == 2
    assert result["event_counts"] == {"total": 1, "settled": 0, "censored": 1}
    assert result["episodes"][0]["censor_reason"] == "segment_end_or_tracking_gap"
    assert "median_settling_time_s" not in result["metrics"]


def test_settle_requires_dwell_and_does_not_count_transient_crossing():
    positions = [0, 0.5, 0.1, 0.4, 0.1, 0.1, 0.1, 0.1]
    frames = [frame(i * 0.1, x) for i, x in enumerate(positions)]
    result = analyze_indo_dynamics(frames, config=cfg())
    assert result["event_counts"]["settled"] == 1
    assert result["episodes"][0]["settle_latency_s"] == pytest.approx(0.6)


def test_low_confidence_splits_episode_and_causes_abstention():
    frames = [frame(i * 0.1, 0.5 if i % 2 else 0.0, 0.1 if i >= 3 else 0.95) for i in range(20)]
    result = analyze_indo_dynamics(frames, config=cfg())
    assert result["status"] == "insufficient_evidence"
    assert "tracking_coverage_below_threshold" in result["abstention_reasons"]
    assert result["metrics"] == {}
    assert result["episodes"] == []


def test_different_sampling_cadence_keeps_stationary_time_fraction_stable():
    slow = [frame(i * 0.2, 0) for i in range(11)]
    fast = [frame(i * 0.05, 0) for i in range(41)]
    for frames in (slow, fast):
        result = analyze_indo_dynamics(frames, config=cfg())
        assert result["metrics"]["center_time_fraction"] == 1.0
        assert result["metrics"]["roller_speed_rms_per_s"] == 0.0


def test_non_monotonic_and_bad_configuration_fail_closed():
    with pytest.raises(ValueError, match="increasing"):
        analyze_indo_dynamics([frame(0.2, 0), frame(0.1, 0)], config=cfg())
    with pytest.raises(ValueError, match="center"):
        analyze_indo_dynamics([frame(0, 0)], config=cfg(center=0.8))


def test_initially_outside_is_not_assumed_to_be_a_new_departure():
    frames = [frame(i * 0.1, 0.5 if i < 5 else 0.0) for i in range(12)]
    result = analyze_indo_dynamics(frames, config=cfg())
    assert result["event_counts"]["total"] == 0


def test_no_data_abstains_and_nonfinite_confidence_cannot_pass():
    assert analyze_indo_dynamics([])["status"] == "insufficient_evidence"
    frames = [frame(i * 0.1, 0.0, math.nan) for i in range(30)]
    assert analyze_indo_dynamics(frames)["metrics"] == {}


def test_cli_writes_source_bound_report(tmp_path):
    from motionos.indo_dynamics import main
    import hashlib
    import json

    def raw_frame(t):
        return {
            "time_s": t,
            "deck": {"left": [0.2, 0.55], "right": [0.8, 0.55], "confidence": 0.95},
            "roller": {"left": [0.47, 0.62], "right": [0.53, 0.62], "confidence": 0.95},
        }

    source = tmp_path / "board-observations.json"
    output = tmp_path / "study" / "dynamics.json"
    source.write_text(json.dumps({"frames": [raw_frame(i / 10) for i in range(61)]}))
    assert main([str(source), str(output)]) == 0
    result = json.loads(output.read_text())
    assert result["schema_version"] == "motionos.indo-dynamics.v1"
    assert result["source_sha256"] == hashlib.sha256(source.read_bytes()).hexdigest()
    assert result["status"] == "descriptive_only"
    assert result["metrics"]["center_time_fraction"] == 1.0


def test_leading_and_trailing_tracking_loss_counts_against_coverage():
    frames = [frame(i * 0.1, 0) for i in range(21)]
    result = analyze_indo_dynamics(frames, config=cfg(), capture_span_s=10.0)
    assert result["quality"]["observed_fraction"] == pytest.approx(0.2)
    assert result["status"] == "insufficient_evidence"
    with pytest.raises(ValueError, match="capture_span_s"):
        analyze_indo_dynamics(frames, config=cfg(), capture_span_s=1.0)
