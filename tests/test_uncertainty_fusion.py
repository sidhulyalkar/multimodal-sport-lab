import pytest

from motionos.uncertainty_fusion import (
    VectorObservation,
    inverse_variance_fuse,
)


def test_inverse_variance_fusion_prefers_more_precise_observation():
    result = inverse_variance_fuse(
        [
            VectorObservation(
                source_id="watch",
                quantity_id="left_wrist_angular_velocity",
                coordinate_frame="body",
                value=(1.0, 2.0, 3.0),
                variance=(0.01, 0.01, 0.01),
                session_time_ns=1_000_000_000,
            ),
            VectorObservation(
                source_id="vision",
                quantity_id="left_wrist_angular_velocity",
                coordinate_frame="body",
                value=(3.0, 4.0, 5.0),
                variance=(1.0, 1.0, 1.0),
                session_time_ns=1_002_000_000,
            ),
        ]
    )

    assert result.value[0] == pytest.approx(1.01980198)
    assert result.variance[0] < 0.01
    assert set(result.source_ids) == {"watch", "vision"}


def test_timing_uncertainty_inflates_effective_variance():
    precise = VectorObservation(
        source_id="watch",
        quantity_id="angular_velocity",
        coordinate_frame="body",
        value=(0.0, 0.0, 0.0),
        variance=(0.01, 0.01, 0.01),
        session_time_ns=1_000_000_000,
        timing_uncertainty_ns=1_000_000,
        maximum_rate_per_s=(10.0, 10.0, 10.0),
    )
    uncertain = VectorObservation(
        source_id="vision",
        quantity_id="angular_velocity",
        coordinate_frame="body",
        value=(10.0, 10.0, 10.0),
        variance=(0.01, 0.01, 0.01),
        session_time_ns=1_000_000_000,
        timing_uncertainty_ns=100_000_000,
        maximum_rate_per_s=(10.0, 10.0, 10.0),
    )

    result = inverse_variance_fuse([precise, uncertain])

    assert result.value[0] < 1.0


def test_fusion_refuses_coordinate_frame_mismatch():
    with pytest.raises(ValueError, match="different frames"):
        inverse_variance_fuse(
            [
                VectorObservation(
                    source_id="watch",
                    quantity_id="gyro",
                    coordinate_frame="watch_sensor",
                    value=(1.0, 0.0, 0.0),
                    variance=(0.1, 0.1, 0.1),
                    session_time_ns=0,
                ),
                VectorObservation(
                    source_id="vision",
                    quantity_id="gyro",
                    coordinate_frame="world",
                    value=(1.0, 0.0, 0.0),
                    variance=(0.1, 0.1, 0.1),
                    session_time_ns=0,
                ),
            ]
        )
