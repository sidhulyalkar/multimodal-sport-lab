from __future__ import annotations

from dataclasses import replace

from .equipment import EquipmentProfile, Vector3
from .schema import SensorEvent


def _vector(payload: dict[str, object], keys: tuple[str, str, str]) -> Vector3:
    try:
        return tuple(float(payload[key]) for key in keys)  # type: ignore[return-value]
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"payload missing numeric vector keys {keys}") from exc


def canonicalize_equipment_imu(
    event: SensorEvent,
    profile: EquipmentProfile,
) -> SensorEvent:
    """Attach calibrated equipment-frame vectors without destroying raw data."""

    if event.stream != "/equipment/imu":
        raise ValueError("equipment IMU adapter only accepts /equipment/imu events")

    accel_sensor = _vector(event.payload, ("ax", "ay", "az"))
    gyro_sensor = _vector(event.payload, ("gx", "gy", "gz"))

    accel_equipment = profile.calibration.transform(accel_sensor)
    gyro_equipment = profile.calibration.transform(gyro_sensor)

    payload = dict(event.payload)
    payload.update(
        {
            "equipment_id": profile.equipment_id,
            "equipment_type": profile.equipment_type,
            "mount_id": profile.mount_id,
            "frame_convention": "+X forward,+Y left,+Z up",
            "accel_sensor": list(accel_sensor),
            "gyro_sensor": list(gyro_sensor),
            "accel_equipment": list(accel_equipment),
            "gyro_equipment": list(gyro_equipment),
        }
    )

    return replace(event, payload=payload)
