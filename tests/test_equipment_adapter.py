import pytest

from motionos.equipment import EquipmentProfile, calibrate_mount_from_static_poses
from motionos.equipment_adapter import (
    ACCEL_STREAM,
    GYRO_STREAM,
    canonicalize_equipment_imu,
    canonicalize_equipment_vector,
)
from motionos.schema import SensorEvent


def _profile() -> EquipmentProfile:
    calibration = calibrate_mount_from_static_poses(
        [(0.0, 0.0, 9.81)] * 10,
        [(-4.146, 0.0, 8.891)] * 10,
    )
    return EquipmentProfile(
        equipment_id="longboard-001",
        equipment_type="longboard",
        mount_id="center-deck-v1",
        calibration=calibration,
    )


def test_equipment_adapter_preserves_combined_raw_and_canonical_frame():
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

    canonical = canonicalize_equipment_imu(event, _profile())

    assert canonical.sequence == event.sequence
    assert canonical.device_time_ns == event.device_time_ns
    assert canonical.payload["temperature_c"] == 22.0
    assert canonical.payload["accel_sensor"] == [1.0, 2.0, 3.0]
    assert canonical.payload["gyro_sensor"] == [0.1, 0.2, 0.3]
    assert canonical.payload["accel_equipment"] == pytest.approx([1.0, 2.0, 3.0])
    assert canonical.payload["gyro_equipment"] == pytest.approx([0.1, 0.2, 0.3])
    assert canonical.payload["equipment_id"] == "longboard-001"


def test_split_accel_event_retains_timestamp_and_only_transforms_accel():
    event = SensorEvent(
        session_id="s",
        device_id="pod",
        stream=ACCEL_STREAM,
        sequence=9,
        device_time_ns=987_654_321,
        payload={
            "ax": 1.0,
            "ay": 2.0,
            "az": 3.0,
            "timestamp_basis": "device_tick_ms",
        },
    )

    canonical = canonicalize_equipment_vector(event, _profile())

    assert canonical.device_time_ns == 987_654_321
    assert canonical.sequence == 9
    assert canonical.payload["accel_sensor"] == [1.0, 2.0, 3.0]
    assert canonical.payload["accel_equipment"] == pytest.approx([1.0, 2.0, 3.0])
    assert "gyro_sensor" not in canonical.payload
    assert canonical.payload["timestamp_basis"] == "device_tick_ms"


def test_split_gyro_event_retains_timestamp_and_only_transforms_gyro():
    event = SensorEvent(
        session_id="s",
        device_id="pod",
        stream=GYRO_STREAM,
        sequence=3,
        device_time_ns=222,
        payload={"gx": 0.1, "gy": 0.2, "gz": 0.3},
    )

    canonical = canonicalize_equipment_imu(event, _profile())

    assert canonical.device_time_ns == 222
    assert canonical.payload["gyro_sensor"] == [0.1, 0.2, 0.3]
    assert canonical.payload["gyro_equipment"] == pytest.approx([0.1, 0.2, 0.3])
    assert "accel_sensor" not in canonical.payload


def test_equipment_adapter_rejects_wrong_stream():
    event = SensorEvent(
        session_id="s",
        device_id="pod",
        stream="/body/watch/imu",
        sequence=0,
        device_time_ns=0,
        payload={"ax": 0, "ay": 0, "az": 1, "gx": 0, "gy": 0, "gz": 0},
    )

    with pytest.raises(ValueError, match="equipment IMU adapter"):
        canonicalize_equipment_imu(event, _profile())
