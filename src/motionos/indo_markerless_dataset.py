from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

from .provenance import sha256_file

INDO_MARKERLESS_DATASET_SCHEMA_VERSION = (
    "motionos.indo-markerless-dataset-index.v1"
)
INDO_MARKERLESS_DATASET_SPEC_SCHEMA_VERSION = (
    "motionos.indo-markerless-dataset-spec.v1"
)

_ALLOWED_REFERENCE_STATUSES = {
    "fiducial_teacher",
    "human_reviewed",
    "human_corrected",
}


def build_markerless_dataset_index(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    """Build a hash-bound frame index for markerless equipment training.

    The index references source videos in place and preserves acquisition
    groups so existing MotionOS grouped-split tooling can partition by run,
    day, viewpoint, subject, or remount without frame leakage.
    """

    spec_file = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("markerless dataset spec must be a JSON object")
    if raw.get("schema_version") not in {
        None,
        INDO_MARKERLESS_DATASET_SPEC_SCHEMA_VERSION,
    }:
        raise ValueError("unsupported markerless dataset spec schema")

    source_specs = raw.get("sources")
    if not isinstance(source_specs, list) or not source_specs:
        raise ValueError("markerless dataset spec requires sources")

    sources: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    seen_sample_ids: set[str] = set()

    for source_index, source_raw in enumerate(source_specs):
        if not isinstance(source_raw, dict):
            raise TypeError(
                f"markerless source {source_index} must be an object"
            )

        labels_path = _resolve(
            _required_text(
                source_raw,
                "teacher_labels",
                source_index,
            ),
            base=spec_file.parent,
        )
        video_path = _resolve(
            _required_text(
                source_raw,
                "video",
                source_index,
            ),
            base=spec_file.parent,
        )

        if not labels_path.is_file():
            raise FileNotFoundError(
                f"teacher labels do not exist: {labels_path}"
            )
        if not video_path.is_file():
            raise FileNotFoundError(
                f"source video does not exist: {video_path}"
            )

        acquisition = {
            "subject_id": _required_text(
                source_raw,
                "subject_id",
                source_index,
            ),
            "day_id": _required_text(
                source_raw,
                "day_id",
                source_index,
            ),
            "run_id": _required_text(
                source_raw,
                "run_id",
                source_index,
            ),
            "remount_id": _required_text(
                source_raw,
                "remount_id",
                source_index,
            ),
            "camera_view": _required_text(
                source_raw,
                "camera_view",
                source_index,
            ),
            "board_id": _required_text(
                source_raw,
                "board_id",
                source_index,
            ),
        }

        label_payload = json.loads(
            labels_path.read_text(encoding="utf-8")
        )
        if not isinstance(label_payload, dict):
            raise TypeError(
                f"teacher labels {labels_path} must contain an object"
            )
        observations = label_payload.get("observations")
        if not isinstance(observations, list):
            raise TypeError(
                f"teacher labels {labels_path} require observations"
            )

        source_id = _source_identity(
            source_raw,
            labels_path=labels_path,
            video_path=video_path,
        )

        accepted = 0
        skipped = 0

        for observation in observations:
            if not isinstance(observation, dict):
                skipped += 1
                continue
            if observation.get("review_status") not in (
                _ALLOWED_REFERENCE_STATUSES
            ):
                skipped += 1
                continue

            frame_index = observation.get("frame_index")
            equipment = observation.get(
                "indo_board_equipment"
            )
            if not isinstance(frame_index, int) or frame_index < 0:
                skipped += 1
                continue
            if not _complete_equipment(equipment):
                skipped += 1
                continue

            observation_source = observation.get("source_id")
            if not isinstance(observation_source, str):
                observation_source = source_id

            sample_id = _sample_id(
                source_id=source_id,
                frame_index=frame_index,
            )
            if sample_id in seen_sample_ids:
                raise ValueError(
                    f"duplicate markerless sample_id: {sample_id}"
                )
            seen_sample_ids.add(sample_id)

            samples.append(
                {
                    "sample_id": sample_id,
                    "source_id": source_id,
                    "observation_source_id":
                        observation_source,
                    "frame_index": frame_index,
                    "camera_pose_sequence":
                        observation.get(
                            "camera_pose_sequence"
                        ),
                    "device_time_ns":
                        observation.get(
                            "device_time_ns"
                        ),
                    "time_s":
                        observation.get("time_s"),
                    "review_status":
                        observation.get(
                            "review_status"
                        ),
                    "video_path": _portable(
                        video_path,
                        base=output.parent,
                    ),
                    "teacher_labels_path": _portable(
                        labels_path,
                        base=output.parent,
                    ),
                    "indo_board_equipment": equipment,
                    **acquisition,
                }
            )
            accepted += 1

        sources.append(
            {
                "source_id": source_id,
                "video_path": _portable(
                    video_path,
                    base=output.parent,
                ),
                "video_sha256":
                    sha256_file(video_path),
                "teacher_labels_path": _portable(
                    labels_path,
                    base=output.parent,
                ),
                "teacher_labels_sha256":
                    sha256_file(labels_path),
                "accepted_sample_count": accepted,
                "skipped_observation_count": skipped,
                **acquisition,
            }
        )

    if not samples:
        raise ValueError(
            "markerless dataset index has no qualified samples"
        )

    samples.sort(
        key=lambda sample: str(sample["sample_id"])
    )
    sources.sort(
        key=lambda source: str(source["source_id"])
    )

    index = {
        "schema_version":
            INDO_MARKERLESS_DATASET_SCHEMA_VERSION,
        "sample_count": len(samples),
        "source_count": len(sources),
        "sources": sources,
        "samples": samples,
        "recommended_primary_group_fields": [
            "subject_id",
            "day_id",
            "run_id",
            "remount_id",
            "camera_view",
        ],
        "claim_boundary": (
            "This index binds source video frames to image-space teacher "
            "geometry and acquisition groups. It does not make the teacher "
            "labels metric biomechanics ground truth."
        ),
    }

    output.write_text(
        json.dumps(index, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    return index


def _complete_equipment(
    value: object,
) -> bool:
    if not isinstance(value, dict):
        return False

    deck = value.get("deck")
    roller = value.get("roller")
    if not isinstance(deck, dict) or not isinstance(roller, dict):
        return False

    return (
        _point(deck.get("left_end")) is not None
        and _point(deck.get("right_end")) is not None
        and _point(roller.get("center")) is not None
    )


def _point(
    value: object,
) -> tuple[float, float] | None:
    if not isinstance(value, list) or len(value) < 2:
        return None
    try:
        x = float(value[0])
        y = float(value[1])
    except (TypeError, ValueError):
        return None
    if not (0 <= x <= 1 and 0 <= y <= 1):
        return None
    return x, y


def _sample_id(
    *,
    source_id: str,
    frame_index: int,
) -> str:
    digest = hashlib.sha256(
        f"{source_id}\0{frame_index}".encode()
    ).hexdigest()[:16]
    return f"indo-equipment/{source_id}/{frame_index:09d}/{digest}"


def _source_identity(
    source: dict[str, Any],
    *,
    labels_path: Path,
    video_path: Path,
) -> str:
    explicit = source.get("source_id")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()

    digest = hashlib.sha256(
        (
            sha256_file(labels_path)
            + "\0"
            + sha256_file(video_path)
        ).encode("utf-8")
    ).hexdigest()[:16]
    return f"indo-source-{digest}"


def _required_text(
    source: dict[str, Any],
    key: str,
    source_index: int,
) -> str:
    value = source.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(
            f"markerless source {source_index}.{key} must be non-empty"
        )
    return value.strip()


def _resolve(
    raw: str,
    *,
    base: Path,
) -> Path:
    path = Path(raw)
    return (
        path.resolve()
        if path.is_absolute()
        else (base / path).resolve()
    )


def _portable(
    path: Path,
    *,
    base: Path,
) -> str:
    return os.path.relpath(
        path.resolve(),
        base.resolve(),
    )
