import json

import pytest

from motionos.clock import ClockModel
from motionos.pose2d_io import (
    fit_embedded_host_clock,
    load_pose2d_journal,
    pair_pose_observations,
)
from motionos.schema import SensorEvent


def _frame(sequence: int, pts: int, host: int) -> SensorEvent:
    return SensorEvent(
        session_id="s1",
        device_id="iphone-rear",
        stream="/camera/frame",
        sequence=sequence,
        device_time_ns=pts,
        payload={
            "host_monotonic_time_ns": host,
        },
    )


def _pose(source: str, sequence: int, pts: int) -> SensorEvent:
    return SensorEvent(
        session_id="s1",
        device_id=source,
        stream="/camera/pose2d",
        sequence=sequence,
        device_time_ns=pts,
        payload={
            "source_frame_sequence": sequence,
            "source_frame_pts_ns": pts,
            "image_width_px": 1000,
            "image_height_px": 500,
            "joint_coordinate_frame": "vision_normalized_lower_left",
            "vision_request": "VNDetectHumanBodyPoseRequest",
            "joints_normalized": {
                "left_wrist": {
                    "x": 0.25,
                    "y": 0.20,
                    "confidence": 0.9,
                }
            },
        },
    )


def test_embedded_host_clock_recovers_affine_mapping():
    model = fit_embedded_host_clock(
        [
            _frame(0, 100, 1_100),
            _frame(1, 1_000_100, 1_001_100),
            _frame(2, 2_000_100, 2_001_100),
            _frame(3, 3_000_100, 3_001_100),
        ]
    )

    assert model.slope == pytest.approx(1.0)
    assert model.intercept_ns == pytest.approx(1_000)
    assert model.residual_rms_ns == pytest.approx(0.0)


def test_pose_journal_converts_vision_coordinates_to_pixels(tmp_path):
    path = tmp_path / "camera.jsonl"
    events = [
        _frame(0, 100, 1_100),
        _frame(1, 1_000_100, 1_001_100),
        _frame(2, 2_000_100, 2_001_100),
        _pose("iphone-rear", 1, 1_000_100),
    ]
    path.write_text(
        "\n".join(event.to_json() for event in events) + "\n",
        encoding="utf-8",
    )

    journal = load_pose2d_journal(
        path,
        source_id="iphone-rear",
    )

    wrist = journal.observations[0].joints["left_wrist"]
    assert wrist.x == pytest.approx(250.0)
    assert wrist.y == pytest.approx(400.0)
    assert journal.observations[0].mapped_session_time_ns == 1_001_100


def test_external_pose_journal_accepts_explicit_clock_model(tmp_path):
    path = tmp_path / "action4.jsonl"
    path.write_text(
        _pose("dji-action4", 7, 2_000_000).to_json() + "\n",
        encoding="utf-8",
    )
    model = ClockModel(
        slope=1.0,
        intercept_ns=5_000,
        residual_rms_ns=2_000_000,
        observations_used=3,
    )

    journal = load_pose2d_journal(
        path,
        source_id="dji-action4",
        clock_model=model,
    )

    assert journal.observations[0].mapped_session_time_ns == 2_005_000
    assert journal.observations[0].timing_uncertainty_ns == 2_000_000


def test_pairing_uses_nearest_mapped_frame_with_frozen_tolerance():
    model = ClockModel(1.0, 0.0, 0.0, 3)
    reference = []
    target = []
    for index, time_ns in enumerate((1_000_000_000, 2_000_000_000)):
        base = _pose("iphone-rear", index, time_ns)
        reference.append(
            load_pose_event_for_test(base, model)
        )
    for index, time_ns in enumerate((1_006_000_000, 2_020_000_000)):
        base = _pose("dji-action4", index, time_ns)
        target.append(
            load_pose_event_for_test(base, model)
        )

    pairs = pair_pose_observations(
        reference,
        target,
        maximum_time_delta_ms=10.0,
    )

    assert len(pairs) == 1
    assert pairs[0][0].frame_sequence == 0
    assert pairs[0][1].frame_sequence == 0


def load_pose_event_for_test(event: SensorEvent, model: ClockModel):
    from motionos.vision_contract import (
        VisionJointObservation,
        VisionObservation,
    )

    return VisionObservation(
        source_id=event.device_id,
        frame_sequence=event.sequence,
        frame_source_time_ns=event.device_time_ns,
        mapped_session_time_ns=model.map(event.device_time_ns),
        timing_uncertainty_ns=0,
        coordinate_frame="image_pixels",
        model_identifier="fixture",
        joints={
            "left_wrist": VisionJointObservation(
                x=100.0,
                y=100.0,
                confidence=0.9,
            )
        },
    )
