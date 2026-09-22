from __future__ import annotations

import json
import math
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path

Vector3 = tuple[float, float, float]
Matrix3 = tuple[Vector3, Vector3, Vector3]


def _dot(a: Vector3, b: Vector3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a: Vector3, b: Vector3) -> Vector3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _norm(v: Vector3) -> float:
    return math.sqrt(_dot(v, v))


def _normalize(v: Vector3) -> Vector3:
    n = _norm(v)
    if n <= 1e-9:
        raise ValueError("cannot normalize near-zero vector")
    return (v[0] / n, v[1] / n, v[2] / n)


def _sub(a: Vector3, b: Vector3) -> Vector3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _scale(v: Vector3, s: float) -> Vector3:
    return (v[0] * s, v[1] * s, v[2] * s)


def _mean(samples: Iterable[Vector3]) -> Vector3:
    values = list(samples)
    if not values:
        raise ValueError("at least one sample is required")
    return (
        sum(v[0] for v in values) / len(values),
        sum(v[1] for v in values) / len(values),
        sum(v[2] for v in values) / len(values),
    )


def determinant(matrix: Matrix3) -> float:
    a, b, c = matrix
    return (
        a[0] * (b[1] * c[2] - b[2] * c[1])
        - a[1] * (b[0] * c[2] - b[2] * c[0])
        + a[2] * (b[0] * c[1] - b[1] * c[0])
    )


def transform_vector(matrix: Matrix3, vector: Vector3) -> Vector3:
    return (
        _dot(matrix[0], vector),
        _dot(matrix[1], vector),
        _dot(matrix[2], vector),
    )


def matrix_is_rotation(matrix: Matrix3, tolerance: float = 1e-6) -> bool:
    rows = matrix
    unit = all(abs(_norm(row) - 1.0) <= tolerance for row in rows)
    orthogonal = (
        abs(_dot(rows[0], rows[1])) <= tolerance
        and abs(_dot(rows[0], rows[2])) <= tolerance
        and abs(_dot(rows[1], rows[2])) <= tolerance
    )
    proper = abs(determinant(matrix) - 1.0) <= tolerance
    return unit and orthogonal and proper


@dataclass(frozen=True)
class MountCalibration:
    """Rigid transform from sensor-frame vectors into equipment coordinates.

    MotionOS equipment convention:
      +X = equipment forward
      +Y = equipment left
      +Z = equipment up
    """

    sensor_to_equipment: Matrix3
    level_mean_accel: Vector3
    nose_up_mean_accel: Vector3
    forward_excitation: float
    orthogonality_error: float

    def __post_init__(self) -> None:
        if not matrix_is_rotation(self.sensor_to_equipment, tolerance=1e-5):
            raise ValueError("sensor_to_equipment must be a proper rotation matrix")

    def transform(self, vector: Vector3) -> Vector3:
        return transform_vector(self.sensor_to_equipment, vector)

    def to_dict(self) -> dict[str, object]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, object]) -> MountCalibration:
        matrix_raw = data["sensor_to_equipment"]
        level_raw = data["level_mean_accel"]
        nose_raw = data["nose_up_mean_accel"]
        if not isinstance(matrix_raw, list | tuple):
            raise TypeError("invalid sensor_to_equipment")
        matrix: Matrix3 = tuple(
            tuple(float(value) for value in row)  # type: ignore[misc]
            for row in matrix_raw
        )  # type: ignore[assignment]
        return cls(
            sensor_to_equipment=matrix,
            level_mean_accel=tuple(float(v) for v in level_raw),  # type: ignore[arg-type]
            nose_up_mean_accel=tuple(float(v) for v in nose_raw),  # type: ignore[arg-type]
            forward_excitation=float(data["forward_excitation"]),
            orthogonality_error=float(data["orthogonality_error"]),
        )


@dataclass(frozen=True)
class EquipmentProfile:
    equipment_id: str
    equipment_type: str
    mount_id: str
    calibration: MountCalibration
    notes: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "equipment_id": self.equipment_id,
            "equipment_type": self.equipment_type,
            "mount_id": self.mount_id,
            "calibration": self.calibration.to_dict(),
            "notes": self.notes,
        }

    @classmethod
    def from_dict(cls, data: dict[str, object]) -> EquipmentProfile:
        calibration = data["calibration"]
        if not isinstance(calibration, dict):
            raise TypeError("calibration must be an object")
        return cls(
            equipment_id=str(data["equipment_id"]),
            equipment_type=str(data["equipment_type"]),
            mount_id=str(data["mount_id"]),
            calibration=MountCalibration.from_dict(calibration),
            notes=str(data["notes"]) if data.get("notes") is not None else None,
        )


def calibrate_mount_from_static_poses(
    level_samples: Iterable[Vector3],
    nose_up_samples: Iterable[Vector3],
    *,
    minimum_excitation: float = 0.15,
) -> MountCalibration:
    """Infer sensor→equipment rotation from level and nose-up static poses.

    At rest, an accelerometer measures a vector parallel to equipment/world up.
    A level pose determines +Z. A deliberate nose-up pitch tilts the gravity
    vector toward -X in equipment coordinates, which resolves yaw around +Z.
    """

    level = _mean(level_samples)
    nose = _mean(nose_up_samples)

    z_sensor = _normalize(level)

    nose_unit = _normalize(nose)
    projected = _sub(nose_unit, _scale(z_sensor, _dot(nose_unit, z_sensor)))
    excitation = _norm(projected)
    if excitation < minimum_excitation:
        raise ValueError(
            "nose-up pose does not sufficiently differ from level pose; "
            "increase the board pitch angle"
        )

    # Nose-up gravity projects toward equipment -X.
    x_sensor = _scale(_normalize(projected), -1.0)
    y_sensor = _normalize(_cross(z_sensor, x_sensor))
    # Re-orthogonalize X to eliminate sample noise.
    x_sensor = _normalize(_cross(y_sensor, z_sensor))

    # Rows are equipment basis vectors expressed in sensor coordinates,
    # yielding v_equipment = R_sensor_to_equipment @ v_sensor.
    rotation: Matrix3 = (x_sensor, y_sensor, z_sensor)

    orthogonality_error = max(
        abs(_dot(x_sensor, y_sensor)),
        abs(_dot(x_sensor, z_sensor)),
        abs(_dot(y_sensor, z_sensor)),
        abs(_norm(x_sensor) - 1.0),
        abs(_norm(y_sensor) - 1.0),
        abs(_norm(z_sensor) - 1.0),
    )

    return MountCalibration(
        sensor_to_equipment=rotation,
        level_mean_accel=level,
        nose_up_mean_accel=nose,
        forward_excitation=excitation,
        orthogonality_error=orthogonality_error,
    )


def save_equipment_profile(profile: EquipmentProfile, path: str | Path) -> Path:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(profile.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return output


def load_equipment_profile(path: str | Path) -> EquipmentProfile:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return EquipmentProfile.from_dict(data)
