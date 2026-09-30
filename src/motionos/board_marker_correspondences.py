from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from .clock import ClockModel


@dataclass(frozen=True)
class MarkerFrame:
    source_id: str
    frame_sequence: int
    source_time_ns: int
    mapped_time_ns: int
    markers: dict[str, dict[str, object]]


def load_marker_frames(
    path: str | Path,
    *,
    clock_model: ClockModel,
) -> tuple[MarkerFrame, ...]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("board marker observations must be an object")
    if raw.get("schema_version") != (
        "motionos.board-marker-observations.v1"
    ):
        raise ValueError("unsupported board marker observations schema")

    source_id = str(raw["source_id"])
    frames_raw = raw.get("frames")
    if not isinstance(frames_raw, list):
        raise TypeError("board marker frames must be a list")

    frames: list[MarkerFrame] = []
    for item in frames_raw:
        if not isinstance(item, dict):
            raise TypeError("board marker frame must be an object")
        markers = item.get("markers")
        if not isinstance(markers, dict):
            raise TypeError("board marker frame markers must be an object")
        source_time = int(item["source_frame_pts_ns"])
        frames.append(
            MarkerFrame(
                source_id=source_id,
                frame_sequence=int(item["source_frame_sequence"]),
                source_time_ns=source_time,
                mapped_time_ns=clock_model.map(source_time),
                markers={
                    str(marker_id): dict(observation)
                    for marker_id, observation in markers.items()
                    if isinstance(observation, dict)
                },
            )
        )

    frames.sort(key=lambda frame: frame.mapped_time_ns)
    if not frames:
        raise ValueError("board marker observation file contains no frames")
    return tuple(frames)


def pair_marker_frames(
    reference: tuple[MarkerFrame, ...],
    target: tuple[MarkerFrame, ...],
    *,
    maximum_time_delta_ms: float = 10.0,
) -> tuple[tuple[MarkerFrame, MarkerFrame], ...]:
    if maximum_time_delta_ms <= 0:
        raise ValueError("maximum_time_delta_ms must be positive")
    if not reference or not target:
        return ()

    max_delta_ns = round(maximum_time_delta_ms * 1e6)
    candidates: list[tuple[int, int, int]] = []
    for reference_index, reference_frame in enumerate(reference):
        for target_index, target_frame in enumerate(target):
            delta = abs(
                reference_frame.mapped_time_ns
                - target_frame.mapped_time_ns
            )
            if delta <= max_delta_ns:
                candidates.append(
                    (delta, reference_index, target_index)
                )

    used_reference: set[int] = set()
    used_target: set[int] = set()
    pairs: list[tuple[MarkerFrame, MarkerFrame]] = []
    for _delta, reference_index, target_index in sorted(candidates):
        if (
            reference_index in used_reference
            or target_index in used_target
        ):
            continue
        pairs.append(
            (
                reference[reference_index],
                target[target_index],
            )
        )
        used_reference.add(reference_index)
        used_target.add(target_index)

    pairs.sort(
        key=lambda pair: (
            pair[0].mapped_time_ns + pair[1].mapped_time_ns
        )
        / 2
    )
    return tuple(pairs)


def build_board_marker_correspondences(
    pairs: tuple[tuple[MarkerFrame, MarkerFrame], ...],
    *,
    rig_id: str,
    rig_receipt_sha256: str,
) -> dict[str, object]:
    points: list[dict[str, object]] = []
    for reference, target in pairs:
        reference_time_ns = round(
            (
                reference.mapped_time_ns
                + target.mapped_time_ns
            )
            / 2
        )
        common_ids = sorted(
            reference.markers.keys() & target.markers.keys(),
            key=int,
        )
        for marker_id in common_ids:
            ref = reference.markers[marker_id]
            tgt = target.markers[marker_id]
            points.append(
                {
                    "point_id": (
                        f"board-marker-{marker_id}-ref-"
                        f"{reference_time_ns}"
                    ),
                    "reference_time_ns": reference_time_ns,
                    "observations": {
                        reference.source_id: {
                            "u_px": float(ref["u_px"]),
                            "v_px": float(ref["v_px"]),
                            "source_frame_sequence":
                                reference.frame_sequence,
                            "source_frame_pts_ns":
                                reference.source_time_ns,
                        },
                        target.source_id: {
                            "u_px": float(tgt["u_px"]),
                            "v_px": float(tgt["v_px"]),
                            "source_frame_sequence":
                                target.frame_sequence,
                            "source_frame_pts_ns":
                                target.source_time_ns,
                        },
                    },
                }
            )

    if not points:
        raise ValueError(
            "no board markers were jointly visible in synchronized frames"
        )
    return {
        "schema_version": "motionos.multiview-correspondences.v1",
        "rig_id": rig_id,
        "rig_receipt_sha256": rig_receipt_sha256,
        "frozen_before_geometry_review": True,
        "pair_count": len(pairs),
        "point_type": "indo_board_aruco_marker_center",
        "points": points,
    }


def write_board_marker_correspondences(
    pairs: tuple[tuple[MarkerFrame, MarkerFrame], ...],
    output_path: str | Path,
    *,
    rig_id: str,
    rig_receipt_path: str | Path,
) -> dict[str, object]:
    rig_path = Path(rig_receipt_path)
    document = build_board_marker_correspondences(
        pairs,
        rig_id=rig_id,
        rig_receipt_sha256=hashlib.sha256(
            rig_path.read_bytes()
        ).hexdigest(),
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return document
