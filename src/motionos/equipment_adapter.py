from __future__ import annotations

from dataclasses import replace

from .equipment import EquipmentProfile, Vector3
from .schema import SensorEvent

ACCEL_STREAM = "/equipment/imu/accel"
GYRO_STREAM = "/equipment/imu/gyro"
SIX_AXIS_STREAM = "/equipment/imu"


def _vector(payload: dict[str, object], keys: tuple[str, str, str]) -> Vector3:
    try:
        return tuple(float(payload[key]) for key in keys)  # type: ignore[return-value]
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"payload missing numeric vector keys {keys}") from exc


def _profile_metadata(profile: EquipmentProfile) -> dict[str, object]:
    return {
        "equipment_id": profile.equipment_id,
        "equipment_type": profile.equipment_type,
        "mount_id": profile.mount_id,
        "frame_convention": "+X forward,+Y left,+Z up",
    }


def canonicalize_equipment_vector(
    event: SensorEvent,
    profile: EquipmentProfile,
) -> SensorEvent:
    """Calibrate one timestamp-faithful accel or gyro event.

    Acceleration and angular velocity remain separate when their source timestamps
    are separate. MotionOS does not invent a simultaneous six-axis sample.
    """

    payload = dict(event.payload)
    payload.update(_profile_metadata(profile))

    if event.stream == ACCEL_STREAM:
        sensor = _vector(event.payload, ("ax", "ay", "az"))
        equipment = profile.calibration.transform(sensor)
        payload.update(
            {
                "accel_sensor": list(sensor),
                "accel_equipment": list(equipment),
            }
        )
    elif event.stream == GYRO_STREAM:
        sensor = _vector(event.payload, ("gx", "gy", "gz"))
        equipment = profile.calibration.transform(sensor)
        payload.update(
            {
                "gyro_sensor": list(sensor),
                "gyro_equipment": list(equipment),
            }
        )
    else:
        raise ValueError(
            "timestamp-faithful equipment vector adapter accepts "
            f"{ACCEL_STREAM} or {GYRO_STREAM}; got {event.stream}"
        )

    return replace(event, payload=payload)


def canonicalize_equipment_imu(
    event: SensorEvent,
    profile: EquipmentProfile,
) -> SensorEvent:
    """Attach equipment-frame vectors without destroying raw sensor evidence.

    Split accel/gyro streams are preferred for MetaMotionS because their board
    timestamps are independent. A combined six-axis event remains supported for
    sensors that genuinely produce a synchronized six-axis observation.
    """

    if event.stream in {ACCEL_STREAM, GYRO_STREAM}:
        return canonicalize_equipment_vector(event, profile)

    if event.stream != SIX_AXIS_STREAM:
        raise ValueError(
            "equipment IMU adapter accepts /equipment/imu or its "
            "/accel and /gyro child streams"
        )

    accel_sensor = _vector(event.payload, ("ax", "ay", "az"))
    gyro_sensor = _vector(event.payload, ("gx", "gy", "gz"))

    accel_equipment = profile.calibration.transform(accel_sensor)
    gyro_equipment = profile.calibration.transform(gyro_sensor)

    payload = dict(event.payload)
    payload.update(_profile_metadata(profile))
    payload.update(
        {
            "accel_sensor": list(accel_sensor),
            "gyro_sensor": list(gyro_sensor),
            "accel_equipment": list(accel_equipment),
            "gyro_equipment": list(gyro_equipment),
        }
    )

    return replace(event, payload=payload)
