from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .schema import SensorEvent
from .sync import nearest_event


@dataclass(frozen=True)
class BodyModel:
    model_id: str
    height_m: float
    segments_m: dict[str, float]
    joint_limits_deg: dict[str, tuple[float, float]]
    metadata: dict[str, Any]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BodyModel":
        limits = {
            key: (float(value[0]), float(value[1]))
            for key, value in data.get("joint_limits_deg", {}).items()
        }
        segments = {key: float(value) for key, value in data.get("segments_m", {}).items()}
        if float(data["height_m"]) <= 0:
            raise ValueError("height_m must be positive")
        if any(value <= 0 for value in segments.values()):
            raise ValueError("all segment lengths must be positive")
        return cls(
            model_id=str(data["model_id"]),
            height_m=float(data["height_m"]),
            segments_m=segments,
            joint_limits_deg=limits,
            metadata=dict(data.get("metadata", {})),
        )


def load_body_model(path: str | Path) -> BodyModel:
    return BodyModel.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))


def align_pose_to_sensor_times(
    pose_events: list[SensorEvent], sensor_times_ns: list[int], *, tolerance_ns: int = 20_000_000
) -> list[SensorEvent | None]:
    return [
        nearest_event(pose_events, timestamp, tolerance_ns=tolerance_ns)
        for timestamp in sensor_times_ns
    ]
