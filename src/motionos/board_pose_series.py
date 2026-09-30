from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from .board_pose import estimate_board_pose, load_board_marker_layout


_POINT_PATTERN = re.compile(
    r"^board-marker-(?P<marker>\d+)-ref-(?P<time>\d+)$"
)


def build_board_pose_series(
    triangulation_report_path: str | Path,
    marker_layout_path: str | Path,
    output_path: str | Path,
    *,
    maximum_scale_error_fraction: float = 0.03,
) -> dict[str, object]:
    triangulation_path = Path(triangulation_report_path).resolve()
    layout_path = Path(marker_layout_path).resolve()
    triangulation = json.loads(
        triangulation_path.read_text(encoding="utf-8")
    )
    if not isinstance(triangulation, dict):
        raise TypeError("triangulation report must be an object")
    if triangulation.get("schema_version") != (
        "motionos.multiview-geometry-report.v1"
    ):
        raise ValueError("unsupported multiview geometry report schema")

    layout = load_board_marker_layout(layout_path)
    points_raw = triangulation.get("points")
    if not isinstance(points_raw, list):
        raise TypeError("triangulation report points must be a list")

    grouped: dict[int, dict[str, tuple[float, float, float]]] = {}
    for point in points_raw:
        if not isinstance(point, dict):
            continue
        match = _POINT_PATTERN.match(str(point.get("point_id", "")))
        if match is None:
            continue
        reference_time_ns = int(point["reference_time_ns"])
        marker_id = match.group("marker")
        raw_position = point.get("world_position_m")
        if (
            not isinstance(raw_position, list)
            or len(raw_position) != 3
        ):
            raise ValueError(
                "triangulated board marker requires world_position_m"
            )
        grouped.setdefault(reference_time_ns, {})[marker_id] = (
            float(raw_position[0]),
            float(raw_position[1]),
            float(raw_position[2]),
        )

    poses: list[dict[str, object]] = []
    rejected: list[dict[str, object]] = []
    for reference_time_ns, markers in sorted(grouped.items()):
        if len(markers) < 3:
            rejected.append(
                {
                    "reference_time_ns": reference_time_ns,
                    "reason": "fewer_than_three_markers",
                    "marker_count": len(markers),
                }
            )
            continue
        try:
            pose = estimate_board_pose(
                layout,
                markers,
                maximum_scale_error_fraction=
                    maximum_scale_error_fraction,
            )
        except ValueError as exc:
            rejected.append(
                {
                    "reference_time_ns": reference_time_ns,
                    "reason": str(exc),
                    "marker_count": len(markers),
                }
            )
            continue

        pose_dict = pose.to_dict()
        pose_dict.pop("schema_version", None)
        pose_dict.pop("claim_boundary", None)
        poses.append(
            {
                "reference_time_ns": reference_time_ns,
                **pose_dict,
            }
        )

    if not poses:
        raise ValueError(
            "no triangulated marker frames produced a valid rigid board pose"
        )

    result: dict[str, object] = {
        "schema_version": "motionos.board-pose-series.v1",
        "layout_id": layout.layout_id,
        "marker_layout_sha256": _sha256(layout_path),
        "triangulation_report_sha256": _sha256(
            triangulation_path
        ),
        "pose_count": len(poses),
        "rejected_frame_count": len(rejected),
        "poses": poses,
        "rejected_frames": rejected,
        "claim_boundary": (
            "Each board pose is a rigid fit of calibrated, triangulated "
            "marker centers to the frozen measured deck layout. Residual "
            "and scale diagnostics remain part of each estimate."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
