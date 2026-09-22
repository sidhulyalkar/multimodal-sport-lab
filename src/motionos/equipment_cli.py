from __future__ import annotations

import json
from pathlib import Path

from .equipment import (
    EquipmentProfile,
    calibrate_mount_from_static_poses,
    save_equipment_profile,
)


def calibrate_equipment_mount_file(
    input_path: str | Path,
    output_path: str | Path,
) -> Path:
    source = Path(input_path)
    data = json.loads(source.read_text(encoding="utf-8"))

    level_samples = _samples(data, "level_samples")
    nose_up_samples = _samples(data, "nose_up_samples")

    calibration = calibrate_mount_from_static_poses(
        level_samples,
        nose_up_samples,
    )
    profile = EquipmentProfile(
        equipment_id=str(data["equipment_id"]),
        equipment_type=str(data["equipment_type"]),
        mount_id=str(data["mount_id"]),
        calibration=calibration,
        notes=str(data["notes"]) if data.get("notes") is not None else None,
    )
    return save_equipment_profile(profile, output_path)


def _samples(data: dict[str, object], key: str) -> list[tuple[float, float, float]]:
    raw = data.get(key)
    if not isinstance(raw, list) or not raw:
        raise ValueError(f"{key} must be a non-empty list")

    samples: list[tuple[float, float, float]] = []
    for index, value in enumerate(raw):
        if not isinstance(value, list | tuple) or len(value) != 3:
            raise ValueError(f"{key}[{index}] must contain exactly three values")
        samples.append((float(value[0]), float(value[1]), float(value[2])))
    return samples
