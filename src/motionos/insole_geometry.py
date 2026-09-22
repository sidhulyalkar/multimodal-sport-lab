from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

INSOLE_GEOMETRY_SCHEMA_VERSION = "motionos.insole-geometry.v1"
CANONICAL_FOOT_FRAME = "+X forward,+Y left,+Z up"


@dataclass(frozen=True)
class PressureSensel:
    index: int
    center_x_m: float
    center_y_m: float
    area_m2: float | None = None

    def __post_init__(self) -> None:
        if self.index <= 0:
            raise ValueError("sensel index must be positive")
        for name, value in (
            ("center_x_m", self.center_x_m),
            ("center_y_m", self.center_y_m),
        ):
            if not math.isfinite(value):
                raise ValueError(f"{name} must be finite")
        if (
            self.area_m2 is not None
            and (
                not math.isfinite(self.area_m2)
                or self.area_m2 <= 0
            )
        ):
            raise ValueError("area_m2 must be positive and finite")

    def to_dict(self) -> dict[str, object]:
        return {
            "index": self.index,
            "center_x_m": self.center_x_m,
            "center_y_m": self.center_y_m,
            "area_m2": self.area_m2,
        }


@dataclass(frozen=True)
class InsoleGeometryProfile:
    vendor: str
    model: str
    size_label: str
    side: str
    origin_description: str
    sensels: tuple[PressureSensel, ...]
    source: str
    cop_normalized_to_meters_affine: (
        tuple[
            tuple[float, float, float],
            tuple[float, float, float],
        ]
        | None
    ) = None
    frame_convention: str = CANONICAL_FOOT_FRAME
    schema_version: str = INSOLE_GEOMETRY_SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.side not in {"left", "right"}:
            raise ValueError("insole geometry side must be 'left' or 'right'")
        if not self.vendor or not self.model or not self.size_label:
            raise ValueError("vendor, model, and size_label are required")
        if not self.origin_description:
            raise ValueError("origin_description is required")
        if not self.source:
            raise ValueError("geometry source/provenance is required")
        if self.frame_convention != CANONICAL_FOOT_FRAME:
            raise ValueError(
                "insole geometry must use the canonical foot frame "
                f"{CANONICAL_FOOT_FRAME!r}"
            )

        indices = [sensel.index for sensel in self.sensels]
        if len(indices) != len(set(indices)):
            raise ValueError("sensel indices must be unique")
        if tuple(sorted(indices)) != tuple(range(1, len(indices) + 1)):
            raise ValueError(
                "sensel indices must be contiguous and 1-based"
            )

        affine = self.cop_normalized_to_meters_affine
        if affine is not None:
            if len(affine) != 2 or any(len(row) != 3 for row in affine):
                raise ValueError("CoP affine transform must be 2x3")
            if not all(
                math.isfinite(value)
                for row in affine
                for value in row
            ):
                raise ValueError("CoP affine transform must be finite")

    def normalized_cop_to_meters(
        self,
        x_normalized: float,
        y_normalized: float,
    ) -> tuple[float, float] | None:
        affine = self.cop_normalized_to_meters_affine
        if affine is None:
            return None
        if not math.isfinite(x_normalized) or not math.isfinite(y_normalized):
            raise ValueError("normalized CoP coordinates must be finite")

        x_row, y_row = affine
        return (
            x_row[0] * x_normalized
            + x_row[1] * y_normalized
            + x_row[2],
            y_row[0] * x_normalized
            + y_row[1] * y_normalized
            + y_row[2],
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "vendor": self.vendor,
            "model": self.model,
            "size_label": self.size_label,
            "side": self.side,
            "frame_convention": self.frame_convention,
            "origin_description": self.origin_description,
            "source": self.source,
            "sensels": [sensel.to_dict() for sensel in self.sensels],
            "cop_normalized_to_meters_affine": (
                [list(row) for row in self.cop_normalized_to_meters_affine]
                if self.cop_normalized_to_meters_affine is not None
                else None
            ),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> InsoleGeometryProfile:
        raw_sensels = data.get("sensels")
        if not isinstance(raw_sensels, list) or not raw_sensels:
            raise ValueError("insole geometry requires a non-empty sensels list")

        sensels = tuple(
            PressureSensel(
                index=int(item["index"]),
                center_x_m=float(item["center_x_m"]),
                center_y_m=float(item["center_y_m"]),
                area_m2=(
                    float(item["area_m2"])
                    if item.get("area_m2") is not None
                    else None
                ),
            )
            for item in raw_sensels
            if isinstance(item, dict)
        )
        if len(sensels) != len(raw_sensels):
            raise TypeError("every sensel entry must be an object")

        raw_affine = data.get("cop_normalized_to_meters_affine")
        affine = None
        if raw_affine is not None:
            if (
                not isinstance(raw_affine, list)
                or len(raw_affine) != 2
                or any(
                    not isinstance(row, list) or len(row) != 3
                    for row in raw_affine
                )
            ):
                raise ValueError("CoP affine transform must be a 2x3 array")
            affine = (
                tuple(float(value) for value in raw_affine[0]),
                tuple(float(value) for value in raw_affine[1]),
            )

        return cls(
            vendor=str(data["vendor"]),
            model=str(data["model"]),
            size_label=str(data["size_label"]),
            side=str(data["side"]),
            frame_convention=str(
                data.get("frame_convention", CANONICAL_FOOT_FRAME)
            ),
            origin_description=str(data["origin_description"]),
            source=str(data["source"]),
            sensels=sensels,
            cop_normalized_to_meters_affine=affine,
            schema_version=str(
                data.get(
                    "schema_version",
                    INSOLE_GEOMETRY_SCHEMA_VERSION,
                )
            ),
        )


def load_insole_geometry_profile(
    path: str | Path,
) -> InsoleGeometryProfile:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("insole geometry profile must contain a JSON object")
    return InsoleGeometryProfile.from_dict(raw)
