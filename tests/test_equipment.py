import math

import pytest

from motionos.equipment import (
    EquipmentProfile,
    calibrate_mount_from_static_poses,
    determinant,
    load_equipment_profile,
    matrix_is_rotation,
    save_equipment_profile,
)


def _rotate_y(vector, angle_deg):
    x, y, z = vector
    angle = math.radians(angle_deg)
    c = math.cos(angle)
    s = math.sin(angle)
    return (
        c * x + s * z,
        y,
        -s * x + c * z,
    )


def _transpose(matrix):
    return tuple(tuple(matrix[j][i] for j in range(3)) for i in range(3))


def _matvec(matrix, vector):
    return tuple(
        sum(matrix[i][j] * vector[j] for j in range(3))
        for i in range(3)
    )


def test_identity_mount_calibration_from_level_and_nose_up():
    level = [(0.0, 0.0, 9.81)] * 20
    # World/equipment up expressed in a board pitched nose-up 25°.
    nose = [(-4.146, 0.0, 8.891)] * 20

    calibration = calibrate_mount_from_static_poses(level, nose)

    assert matrix_is_rotation(calibration.sensor_to_equipment)
    assert determinant(calibration.sensor_to_equipment) == pytest.approx(1.0)
    assert calibration.transform((1.0, 0.0, 0.0)) == pytest.approx((1.0, 0.0, 0.0))
    assert calibration.transform((0.0, 1.0, 0.0)) == pytest.approx((0.0, 1.0, 0.0))
    assert calibration.transform((0.0, 0.0, 1.0)) == pytest.approx((0.0, 0.0, 1.0))


def test_calibration_recovers_arbitrary_sensor_mount_orientation():
    # Rows: sensor->equipment. Proper 90-degree rotation around equipment Z.
    sensor_to_equipment = (
        (0.0, -1.0, 0.0),
        (1.0, 0.0, 0.0),
        (0.0, 0.0, 1.0),
    )
    equipment_to_sensor = _transpose(sensor_to_equipment)

    level_equipment = (0.0, 0.0, 9.81)
    nose_equipment = (-4.146, 0.0, 8.891)

    level_sensor = _matvec(equipment_to_sensor, level_equipment)
    nose_sensor = _matvec(equipment_to_sensor, nose_equipment)

    calibration = calibrate_mount_from_static_poses(
        [level_sensor] * 30,
        [nose_sensor] * 30,
    )

    for actual_row, expected_row in zip(
        calibration.sensor_to_equipment,
        sensor_to_equipment,
    ):
        assert actual_row == pytest.approx(expected_row, abs=1e-3)


def test_calibration_rejects_insufficient_pitch_excitation():
    with pytest.raises(ValueError, match="increase the board pitch"):
        calibrate_mount_from_static_poses(
            [(0.0, 0.0, 9.81)] * 10,
            [(0.01, 0.0, 9.81)] * 10,
        )


def test_equipment_profile_round_trip(tmp_path):
    calibration = calibrate_mount_from_static_poses(
        [(0.0, 0.0, 9.81)] * 10,
        [(-4.146, 0.0, 8.891)] * 10,
    )
    profile = EquipmentProfile(
        equipment_id="longboard-001",
        equipment_type="longboard",
        mount_id="center-deck-v1",
        calibration=calibration,
        notes="temporary Dual Lock mount",
    )

    path = save_equipment_profile(profile, tmp_path / "longboard.json")
    loaded = load_equipment_profile(path)

    assert loaded.equipment_id == profile.equipment_id
    assert loaded.mount_id == profile.mount_id
    for actual_row, expected_row in zip(
        loaded.calibration.sensor_to_equipment,
        profile.calibration.sensor_to_equipment,
    ):
        assert actual_row == pytest.approx(expected_row)
