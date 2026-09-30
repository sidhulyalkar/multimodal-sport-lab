from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .body_model import fit_similarity_transform

Vector3 = tuple[float, float, float]


@dataclass(frozen=True)
class BoardMarkerLayout:
    layout_id: str
    frame_convention: str
    markers_m: dict[str, Vector3]
    marker_dictionary: str | None = None

    def __post_init__(self) -> None:
        if len(self.markers_m) < 3:
            raise ValueError("board layout requires at least three markers")
        if not self.frame_convention.strip():
            raise ValueError("board frame convention is required")

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BoardMarkerLayout:
        raw = data.get("markers_m")
        if not isinstance(raw, dict):
            raise TypeError("markers_m must be an object")
        markers: dict[str, Vector3] = {}
        for marker_id, point in raw.items():
            if not isinstance(point, list) or len(point) != 3:
                raise ValueError(
                    f"marker {marker_id!r} must contain three coordinates"
                )
            markers[str(marker_id)] = (
                float(point[0]),
                float(point[1]),
                float(point[2]),
            )
        return cls(
            layout_id=str(data["layout_id"]),
            frame_convention=str(data["frame_convention"]),
            markers_m=markers,
            marker_dictionary=(
                str(data["marker_dictionary"])
                if data.get("marker_dictionary") is not None
                else None
            ),
        )


@dataclass(frozen=True)
class BoardPoseEstimate:
    layout_id: str
    translation_world_m: Vector3
    rotation_world_from_board: tuple[
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
    ]
    roll_deg: float
    pitch_deg: float
    yaw_deg: float
    residual_rms_m: float
    residual_max_m: float
    marker_count: int
    fitted_scale: float

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": "motionos.board-pose.v1",
            "layout_id": self.layout_id,
            "translation_world_m": list(self.translation_world_m),
            "rotation_world_from_board": [
                list(row) for row in self.rotation_world_from_board
            ],
            "roll_deg": self.roll_deg,
            "pitch_deg": self.pitch_deg,
            "yaw_deg": self.yaw_deg,
            "residual_rms_m": self.residual_rms_m,
            "residual_max_m": self.residual_max_m,
            "marker_count": self.marker_count,
            "fitted_scale": self.fitted_scale,
            "claim_boundary": (
                "Pose is a rigid-board estimate from declared marker geometry "
                "and triangulated marker positions; residuals remain part of "
                "the evidence."
            ),
        }


def load_board_marker_layout(path: str | Path) -> BoardMarkerLayout:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("board marker layout must contain a JSON object")
    return BoardMarkerLayout.from_dict(raw)


def estimate_board_pose(
    layout: BoardMarkerLayout,
    observed_world_markers_m: dict[str, Vector3],
    *,
    maximum_scale_error_fraction: float = 0.03,
) -> BoardPoseEstimate:
    shared = tuple(
        marker_id
        for marker_id in sorted(layout.markers_m)
        if marker_id in observed_world_markers_m
    )
    if len(shared) < 3:
        raise ValueError(
            "board pose requires at least three shared non-collinear markers"
        )

    source = {
        marker_id: layout.markers_m[marker_id]
        for marker_id in shared
    }
    target = {
        marker_id: observed_world_markers_m[marker_id]
        for marker_id in shared
    }
    transform, residuals = fit_similarity_transform(
        source,
        target,
        landmark_order=shared,
    )
    if abs(transform.scale - 1.0) > maximum_scale_error_fraction:
        raise ValueError(
            "observed board marker geometry changed scale beyond tolerance"
        )

    roll, pitch, yaw = _rotation_to_rpy_deg(transform.rotation)
    values = tuple(residuals.values())
    rms = math.sqrt(
        sum(value * value for value in values) / len(values)
    )

    return BoardPoseEstimate(
        layout_id=layout.layout_id,
        translation_world_m=transform.translation_m,
        rotation_world_from_board=transform.rotation,
        roll_deg=roll,
        pitch_deg=pitch,
        yaw_deg=yaw,
        residual_rms_m=rms,
        residual_max_m=max(values),
        marker_count=len(shared),
        fitted_scale=transform.scale,
    )


def _rotation_to_rpy_deg(
    rotation: tuple[
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
    ],
) -> tuple[float, float, float]:
    # Right-handed board frame. R = Rz(yaw) * Ry(pitch) * Rx(roll).
    sin_pitch = max(-1.0, min(1.0, -rotation[2][0]))
    pitch = math.asin(sin_pitch)
    cosine_pitch = math.cos(pitch)

    if abs(cosine_pitch) > 1e-8:
        roll = math.atan2(rotation[2][1], rotation[2][2])
        yaw = math.atan2(rotation[1][0], rotation[0][0])
    else:
        roll = 0.0
        yaw = math.atan2(-rotation[0][1], rotation[1][1])

    return tuple(
        math.degrees(value)
        for value in (roll, pitch, yaw)
    )
