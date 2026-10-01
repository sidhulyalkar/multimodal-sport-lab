import math

import pytest

from motionos.vision_contract import (
    VisionJointObservation,
    VisionObservation,
)
from motionos.vision_sync import estimate_external_camera_clock


def _series(
    *,
    source_id: str,
    source_start_ns: int,
    mapped_offset_ns: int | None,
    impulse_source_times_ns: tuple[int, ...],
) -> tuple[VisionObservation, ...]:
    observations = []
    step_ns = 100_000_000
    for index in range(110):
        source_time = source_start_ns + index * step_ns
        x = 100.0 + 2.0 * math.sin(index / 10.0)
        if any(
            abs(source_time - impulse) <= 20_000_000
            for impulse in impulse_source_times_ns
        ):
            x += 160.0

        mapped = (
            source_time + mapped_offset_ns
            if mapped_offset_ns is not None
            else None
        )
        observations.append(
            VisionObservation(
                source_id=source_id,
                frame_sequence=index,
                frame_source_time_ns=source_time,
                mapped_session_time_ns=mapped,
                timing_uncertainty_ns=1_000_000,
                coordinate_frame="image_pixels",
                model_identifier="fixture",
                joints={
                    "left_wrist": VisionJointObservation(
                        x=x,
                        y=100.0,
                        confidence=0.95,
                    ),
                    "right_wrist": VisionJointObservation(
                        x=x + 10.0,
                        y=110.0,
                        confidence=0.95,
                    ),
                },
            )
        )
    return tuple(observations)


def test_external_clock_uses_physical_impulses_not_cue_latency():
    host_impulses = (
        2_000_000_000,
        5_000_000_000,
        8_000_000_000,
    )
    cue_times = (
        1_700_000_000,
        4_700_000_000,
        7_700_000_000,
    )
    iphone = _series(
        source_id="iphone-rear",
        source_start_ns=0,
        mapped_offset_ns=0,
        impulse_source_times_ns=host_impulses,
    )

    # Action 4 PTS is exactly one second behind the host clock.
    action_impulses = tuple(
        value - 1_000_000_000
        for value in host_impulses
    )
    external = _series(
        source_id="dji-action4",
        source_start_ns=0,
        mapped_offset_ns=None,
        impulse_source_times_ns=action_impulses,
    )

    result = estimate_external_camera_clock(
        iphone,
        external,
        cue_times,
        cue_search_after_ms=1000,
        maximum_residual_ms=30,
    )

    assert result.model.slope == pytest.approx(1.0, abs=1e-6)
    assert result.model.intercept_ns == pytest.approx(
        1_000_000_000,
        abs=20_000_000,
    )
    assert result.model.residual_rms_ns / 1e6 < 30
    assert len(result.external_impulse_peaks) == 3


def test_external_sync_requires_three_landmarks():
    with pytest.raises(ValueError, match="at least three"):
        estimate_external_camera_clock(
            _series(
                source_id="iphone-rear",
                source_start_ns=0,
                mapped_offset_ns=0,
                impulse_source_times_ns=(1_000_000_000,),
            ),
            _series(
                source_id="dji-action4",
                source_start_ns=0,
                mapped_offset_ns=None,
                impulse_source_times_ns=(1_000_000_000,),
            ),
            (900_000_000,),
        )
