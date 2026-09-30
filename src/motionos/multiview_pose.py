from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from statistics import median
from collections.abc import Iterable

from .vision_contract import VisionObservation


@dataclass(frozen=True)
class SkeletonCorrespondenceResult:
    reference_time_ns: int
    accepted_joint_count: int
    rejected_joint_count: int
    points: tuple[dict[str, object], ...]

    def to_correspondence_document(
        self,
        *,
        rig_id: str,
        rig_receipt_sha256: str,
    ) -> dict[str, object]:
        return {
            "schema_version": "motionos.multiview-correspondences.v1",
            "rig_id": rig_id,
            "rig_receipt_sha256": rig_receipt_sha256,
            "frozen_before_geometry_review": True,
            "points": list(self.points),
        }


def build_skeleton_correspondences(
    observations: Iterable[VisionObservation],
    *,
    minimum_joint_confidence: float = 0.6,
    maximum_frame_time_delta_ms: float = 10.0,
) -> SkeletonCorrespondenceResult:
    frames = tuple(observations)
    if len(frames) < 2:
        raise ValueError("multiview skeleton requires at least two cameras")
    source_ids = [frame.source_id for frame in frames]
    if len(set(source_ids)) != len(source_ids):
        raise ValueError("one frame per camera source is required")
    if any(frame.coordinate_frame != "image_pixels" for frame in frames):
        raise ValueError(
            "skeleton correspondence input must use image_pixels coordinates"
        )
    if any(frame.mapped_session_time_ns is None for frame in frames):
        raise ValueError(
            "all camera frames must be mapped to the reference session clock"
        )

    mapped_times = [
        int(frame.mapped_session_time_ns)
        for frame in frames
        if frame.mapped_session_time_ns is not None
    ]
    reference_time_ns = round(median(mapped_times))
    span_ns = max(mapped_times) - min(mapped_times)
    if span_ns / 1e6 > maximum_frame_time_delta_ms:
        raise ValueError(
            "camera frame timing span exceeds correspondence threshold"
        )

    all_joint_names = sorted(
        set().union(*(frame.joints.keys() for frame in frames))
    )
    points: list[dict[str, object]] = []
    rejected = 0
    for joint_name in all_joint_names:
        joint_observations: dict[str, object] = {}
        for frame in frames:
            joint = frame.joints.get(joint_name)
            if joint is None or joint.confidence < minimum_joint_confidence:
                continue
            joint_observations[frame.source_id] = {
                "u_px": joint.x,
                "v_px": joint.y,
                "source_frame_sequence": frame.frame_sequence,
                "source_frame_pts_ns": frame.frame_source_time_ns,
                "joint_confidence": joint.confidence,
            }

        if len(joint_observations) < 2:
            rejected += 1
            continue

        points.append(
            {
                "point_id": (
                    f"{joint_name}-ref-{reference_time_ns}"
                ),
                "reference_time_ns": reference_time_ns,
                "observations": joint_observations,
            }
        )

    if not points:
        raise ValueError("no joints passed the multiview confidence gate")

    return SkeletonCorrespondenceResult(
        reference_time_ns=reference_time_ns,
        accepted_joint_count=len(points),
        rejected_joint_count=rejected,
        points=tuple(points),
    )


def write_skeleton_correspondences(
    observations: Iterable[VisionObservation],
    output_path: str | Path,
    *,
    rig_id: str,
    rig_receipt_path: str | Path,
    minimum_joint_confidence: float = 0.6,
    maximum_frame_time_delta_ms: float = 10.0,
) -> dict[str, object]:
    rig_path = Path(rig_receipt_path)
    rig_sha = hashlib.sha256(rig_path.read_bytes()).hexdigest()
    result = build_skeleton_correspondences(
        observations,
        minimum_joint_confidence=minimum_joint_confidence,
        maximum_frame_time_delta_ms=maximum_frame_time_delta_ms,
    )
    document = result.to_correspondence_document(
        rig_id=rig_id,
        rig_receipt_sha256=rig_sha,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return document
