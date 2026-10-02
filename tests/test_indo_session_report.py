import json
from pathlib import Path

from motionos.indo_session_report import build_indo_session_report


def _taxonomy_path() -> Path:
    return Path("configs/indo_skill_taxonomy.v1.json")


def _board_frame(time_s: float, position: float):
    center = 0.5
    half_length = 0.3
    roller_x = center + position * half_length
    return {
        "time_s": time_s,
        "deck": {
            "left": [0.2, 0.55],
            "right": [0.8, 0.55],
            "confidence": 0.95,
        },
        "roller": {
            "left": [roller_x - 0.03, 0.62],
            "right": [roller_x + 0.03, 0.62],
            "confidence": 0.93,
        },
    }


def test_session_report_works_with_camera_only():
    report = build_indo_session_report(
        session_id="session-camera",
        taxonomy_path=_taxonomy_path(),
        body_metrics={
            "metrics": {
                "median_knee_flexion_deg": 8.0,
                "trunk_excursion": 0.12,
            },
            "confidence": {
                "median_knee_flexion_deg": 0.9,
                "trunk_excursion": 0.85,
            },
            "claim_boundary": "body-only",
        },
    )

    assert report["available_channels"] == [
        "body_pose_2d",
        "body_pose_3d",
    ]
    assert report["primary_coaching"]["rule_id"] == (
        "stiff_knee_strategy"
    )
    assert report["updated_profile"]["session_ids"] == [
        "session-camera"
    ]


def test_session_report_uses_board_recovery_evidence():
    positions = [
        0.0,
        0.20,
        0.40,
        0.60,
        0.45,
        0.22,
        0.10,
        -0.24,
        -0.42,
        -0.18,
        0.08,
        0.0,
    ] * 15

    report = build_indo_session_report(
        session_id="session-board",
        taxonomy_path=_taxonomy_path(),
        body_metrics={
            "metrics": {
                "median_knee_flexion_deg": 22.0,
                "trunk_excursion": 0.04,
            },
            "confidence": {
                "median_knee_flexion_deg": 0.9,
                "trunk_excursion": 0.9,
            },
        },
        board_observations={
            "frames": [
                _board_frame(index * 0.1, position)
                for index, position in enumerate(positions)
            ]
        },
    )

    assert "board_pose" in report["available_channels"]
    assert "roller_state" in report["available_channels"]
    assert report["board_report"]["frame_count"] == len(
        positions
    )
    assert "recovery_time_ms" in report["metrics"]
    assert report["primary_coaching"] is not None


def test_session_report_falls_back_without_overclaiming():
    report = build_indo_session_report(
        session_id="session-sparse",
        taxonomy_path=_taxonomy_path(),
        body_metrics={
            "metrics": {
                "median_knee_flexion_deg": 24.0,
                "trunk_excursion": 0.03,
            },
            "confidence": {
                "median_knee_flexion_deg": 0.7,
                "trunk_excursion": 0.7,
            },
        },
    )

    assert report["primary_coaching"]["rule_id"] == (
        "collect_comparable_baseline"
    )
    assert report["primary_coaching"]["confidence"] < 0.5
    json.dumps(report)
