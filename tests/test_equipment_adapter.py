import pytest

from motionos.equipment import EquipmentProfile, calibrate_mount_from_static_poses
from motionos.equipment_adapter import canonicalize_equipment_imu
from motionos.schema import SensorEvent


def test_equipment_adapter_preserves_raw_and_adds_canonical_frame():
    calibration = calibrate_mount_from_static_poses(
        [(0.0, 0.0, 9.81)] * 10,
        [(-4.146, 0.0, 8.891)] * 10,
    )
    profile = EquipmentProfile(
        equipment_id="longboard-001",
        equipment_type="longboard",
        mount_id="center-deck-v1",
        calibration=calibration,
    )
    event = SensorEvent(
        session_id="s",
        device_id="pod",
        stream="/equipment/imu",
        sequence=4,
        device_time_ns=123,
        payload={
            "ax": 1.0,
            "ay": 2.0,
            "az": 3.0,
            "gx": 0.1,
            "gy": 0.2,
            "gz": 0.3,
            "temperature_c": 22.0,
        },
    )

    canonical = canonicalize_equipment_imu(event, profile)

    assert canonical.sequence == event.sequence
    assert canonical.device_time_ns == event.device_time_ns
    assert canonical.payload["temperature_c"] == 22.0
    assert canonical.payload["accel_sensor"] == [1.0, 2.0, 3.0]
    assert canonical.payload["gyro_sensor"] == [0.1, 0.2, 0.3]
    assert canonical.payload["accel_equipment"] == pytest.approx([1.0, 2.0, 3.0])
    assert canonical.payload["gyro_equipment"] == pytest.approx([0.1, 0.2, 0.3])
    assert canonical.payload["equipment_id"] == "longboard-001"


def test_equipment_adapter_rejects_wrong_stream():
    calibration = calibrate_mount_from_static_poses(
        [(0.0, 0.0, 9.81)] * 10,
        [(-4.146, 0.0, 8.891)] * 10,
    )
    profile = EquipmentProfile(
        equipment_id="x",
        equipment_type="board",
        mount_id="m",
        calibration=calibration,
    )
    event = SensorEvent(
        session_id="s",
        device_id="pod",
        stream="/body/watch/imu",
        sequence=0,
        device_time_ns=0,
        payload={"ax": 0, "ay": 0, "az": 1, "gx": 0, "gy": 0, "gz": 0},
    )

    with pytest.raises(ValueError, match="/equipment/imu"):
        canonicalize_equipment_imu(event, profile)
