import math

import pytest

from motionos.board_pose import BoardMarkerLayout, estimate_board_pose


def _rotate_y(point, degrees):
    angle = math.radians(degrees)
    c = math.cos(angle)
    s = math.sin(angle)
    x, y, z = point
    return (
        c * x + s * z,
        y,
        -s * x + c * z,
    )


def test_board_pose_recovers_rigid_translation_and_yaw():
    layout = BoardMarkerLayout(
        layout_id="fixture",
        frame_convention="fixture",
        markers_m={
            "a": (-0.2, 0.0, 0.3),
            "b": (0.2, 0.0, 0.3),
            "c": (-0.2, 0.0, -0.3),
            "d": (0.2, 0.0, -0.3),
        },
    )
    observed = {}
    for marker_id, point in layout.markers_m.items():
        rotated = _rotate_y(point, 12.0)
        observed[marker_id] = (
            rotated[0] + 1.0,
            rotated[1] + 0.2,
            rotated[2] + 2.0,
        )

    pose = estimate_board_pose(layout, observed)

    assert pose.translation_world_m == pytest.approx((1.0, 0.2, 2.0))
    assert pose.pitch_deg == pytest.approx(12.0, abs=1e-6)
    assert pose.roll_deg == pytest.approx(0.0, abs=1e-6)
    assert pose.yaw_deg == pytest.approx(0.0, abs=1e-6)
    assert pose.residual_rms_m < 1e-8
    assert pose.fitted_scale == pytest.approx(1.0)


def test_board_pose_rejects_geometry_scale_change():
    layout = BoardMarkerLayout(
        layout_id="fixture",
        frame_convention="fixture",
        markers_m={
            "a": (0.0, 0.0, 0.0),
            "b": (1.0, 0.0, 0.0),
            "c": (0.0, 0.0, 1.0),
        },
    )
    observed = {
        marker_id: tuple(1.1 * value for value in point)
        for marker_id, point in layout.markers_m.items()
    }

    with pytest.raises(ValueError, match="changed scale"):
        estimate_board_pose(layout, observed)
