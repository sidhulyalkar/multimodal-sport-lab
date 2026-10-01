from dataclasses import replace

from motionos.indo_board import IndoBoardSample, analyze_indo_board
from motionos.longitudinal import (
    load_longitudinal_profile,
    update_longitudinal_profile,
    update_longitudinal_profile_if_qualified,
)


def _report(session_id: str, offset: float = 0.0):
    samples = [
        IndoBoardSample(
            time_s=index * 0.1,
            com_x_m=0.01 * ((index % 3) - 1) + offset,
            com_y_m=0.9,
            com_z_m=0.005 * ((index % 5) - 2),
            board_roll_deg=float((index % 4) - 2),
            board_pitch_deg=0.5,
            left_knee_flexion_deg=30.0,
            right_knee_flexion_deg=32.0,
            pose_confidence=0.95,
            timing_uncertainty_ms=2.0,
            reprojection_rms_px=0.5,
        )
        for index in range(40)
    ]
    return analyze_indo_board(samples, session_id=session_id)


def test_longitudinal_profile_persists_and_rejects_duplicate_session(tmp_path):
    path = tmp_path / "indo-board-profile.json"

    first = update_longitudinal_profile(path, _report("s1"))
    assert first.processed_session_ids == ["s1"]
    count = first.metric_baselines["balance_stability_rms_m"].sample_count
    assert count == 1

    duplicate = update_longitudinal_profile(path, _report("s1"))
    assert duplicate.metric_baselines[
        "balance_stability_rms_m"
    ].sample_count == 1

    second = update_longitudinal_profile(path, _report("s2", offset=0.01))
    assert second.processed_session_ids == ["s1", "s2"]
    assert second.metric_baselines[
        "balance_stability_rms_m"
    ].sample_count == 2

    reloaded = load_longitudinal_profile(path)
    assert reloaded.to_dict() == second.to_dict()


def test_low_confidence_metric_does_not_update_baseline(tmp_path):
    path = tmp_path / "indo-board-profile.json"
    report = _report("s-low")
    metrics = tuple(
        replace(metric, confidence=0.2)
        for metric in report.metrics
    )
    report = replace(report, metrics=metrics)

    profile = update_longitudinal_profile(path, report)

    assert profile.processed_session_ids == ["s-low"]
    assert profile.metric_baselines == {}



def test_unqualified_session_cannot_mutate_longitudinal_profile(tmp_path):
    path = tmp_path / "indo-board-profile.json"

    profile, changed = update_longitudinal_profile_if_qualified(
        path,
        _report("rejected-session"),
        qualification_passed=False,
    )

    assert changed is False
    assert profile.processed_session_ids == []
    assert profile.metric_baselines == {}
    assert not path.exists()


def test_qualified_session_updates_once_and_duplicate_is_idempotent(tmp_path):
    path = tmp_path / "indo-board-profile.json"
    report = _report("qualified-session")

    first, first_changed = update_longitudinal_profile_if_qualified(
        path,
        report,
        qualification_passed=True,
    )
    second, second_changed = update_longitudinal_profile_if_qualified(
        path,
        report,
        qualification_passed=True,
    )

    assert first_changed is True
    assert second_changed is False
    assert first.processed_session_ids == ["qualified-session"]
    assert second.metric_baselines[
        "balance_stability_rms_m"
    ].sample_count == 1
