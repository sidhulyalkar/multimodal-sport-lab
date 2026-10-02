from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path
from typing import Any

INDO_ANNOTATION_QUEUE_SCHEMA_VERSION = "motionos.indo-annotation-queue.v1"
INDO_FRAME_ANNOTATION_SCHEMA_VERSION = "motionos.indo-frame-annotation.v1"

_REQUIRED_EQUIPMENT_LABELS = {
    "deck",
    "roller",
}


def build_annotation_queue(
    catalog_path: str | Path,
    taxonomy_path: str | Path,
    output_path: str | Path,
    *,
    max_sources: int | None = None,
) -> dict[str, Any]:
    catalog = _load_object(catalog_path)
    taxonomy = _load_object(taxonomy_path)

    records = catalog.get("records")
    skills = taxonomy.get("skills")
    if not isinstance(records, list):
        raise TypeError("catalog records must be a list")
    if not isinstance(skills, list):
        raise TypeError("taxonomy skills must be a list")

    skill_ids = {
        str(skill["id"])
        for skill in skills
        if isinstance(skill, dict) and skill.get("id")
    }

    tasks: list[dict[str, Any]] = []
    for raw in records:
        if not isinstance(raw, dict):
            continue
        source_id = raw.get("source_id")
        source_url = raw.get("source_url")
        if not isinstance(source_id, str) or not source_id:
            continue
        if not isinstance(source_url, str) or not source_url:
            continue

        weak_labels = raw.get("weak_labels")
        if not isinstance(weak_labels, list):
            weak_labels = []

        creator = str(raw.get("creator") or "unknown")
        rights_status = str(raw.get("rights_status") or "unknown")
        retention_policy = str(
            raw.get("retention_policy") or "derived_only"
        )

        task = {
            "task_id": _task_id(source_id),
            "source_id": source_id,
            "source_url": source_url,
            "creator": creator,
            "rights_status": rights_status,
            "retention_policy": retention_policy,
            "split_group": creator,
            "priority": _priority(raw),
            "weak_labels": sorted(
                {
                    str(value)
                    for value in weak_labels
                    if str(value).strip()
                }
            ),
            "requested_annotations": {
                "equipment": [
                    "deck_polygon",
                    "deck_left_endpoint",
                    "deck_right_endpoint",
                    "roller_left_endpoint",
                    "roller_right_endpoint",
                ],
                "events": [
                    "mount",
                    "neutral_hold",
                    "intentional_shift",
                    "squat",
                    "single_leg_unweight",
                    "recovery",
                    "near_edge",
                    "edge_or_stop_touch",
                    "step_off",
                    "bailout",
                    "occlusion",
                ],
                "skills": sorted(skill_ids),
            },
            "review_policy": (
                "Model proposals require human review before becoming "
                "evaluation ground truth."
            ),
        }
        tasks.append(task)

    tasks.sort(
        key=lambda task: (
            -int(task["priority"]),
            str(task["creator"]).lower(),
            str(task["source_id"]),
        )
    )
    if max_sources is not None:
        if max_sources < 1:
            raise ValueError("max_sources must be positive")
        tasks = tasks[:max_sources]

    _assign_grouped_splits(tasks)

    payload = {
        "schema_version": INDO_ANNOTATION_QUEUE_SCHEMA_VERSION,
        "task_count": len(tasks),
        "split_counts": dict(
            Counter(str(task["split"]) for task in tasks)
        ),
        "tasks": tasks,
        "claim_boundary": (
            "This queue organizes annotation work. Weak labels and model "
            "proposals are not biomechanics ground truth. Creator-grouped "
            "splits reduce leakage from near-duplicate channel content."
        ),
    }
    _write_json(output_path, payload)
    return payload


def validate_frame_annotation(
    payload: object,
) -> None:
    if not isinstance(payload, dict):
        raise TypeError("frame annotation must be a JSON object")
    if (
        payload.get("schema_version")
        != INDO_FRAME_ANNOTATION_SCHEMA_VERSION
    ):
        raise ValueError("unsupported frame annotation schema")

    source_id = payload.get("source_id")
    if not isinstance(source_id, str) or not source_id:
        raise ValueError("source_id must be non-empty")

    frame_index = payload.get("frame_index")
    if not isinstance(frame_index, int) or frame_index < 0:
        raise ValueError("frame_index must be a non-negative integer")

    time_s = payload.get("time_s")
    if not isinstance(time_s, (int, float)) or time_s < 0:
        raise ValueError("time_s must be non-negative")

    equipment = payload.get("equipment")
    if not isinstance(equipment, dict):
        raise TypeError("equipment must be an object")

    labels_present = {
        label
        for label, value in equipment.items()
        if isinstance(value, dict)
    }
    missing = _REQUIRED_EQUIPMENT_LABELS - labels_present
    if missing:
        raise ValueError(
            "frame annotation is missing equipment: "
            + ", ".join(sorted(missing))
        )

    _validate_deck(equipment["deck"])
    _validate_roller(equipment["roller"])

    events = payload.get("events", [])
    if not isinstance(events, list) or not all(
        isinstance(event, str) and event
        for event in events
    ):
        raise TypeError("events must be a list of non-empty strings")

    skill_labels = payload.get("skill_labels", [])
    if not isinstance(skill_labels, list) or not all(
        isinstance(label, str) and label
        for label in skill_labels
    ):
        raise TypeError(
            "skill_labels must be a list of non-empty strings"
        )

    review = payload.get("review")
    if not isinstance(review, dict):
        raise TypeError("review must be an object")
    if review.get("status") not in {
        "model_proposed",
        "human_reviewed",
        "human_corrected",
        "rejected",
    }:
        raise ValueError("review.status is unsupported")


def new_frame_annotation(
    *,
    source_id: str,
    frame_index: int,
    time_s: float,
    deck_polygon: list[list[float]],
    deck_left: list[float],
    deck_right: list[float],
    roller_left: list[float],
    roller_right: list[float],
    equipment_confidence: float,
    events: list[str] | None = None,
    skill_labels: list[str] | None = None,
    review_status: str = "model_proposed",
    model_id: str | None = None,
) -> dict[str, Any]:
    payload = {
        "schema_version": INDO_FRAME_ANNOTATION_SCHEMA_VERSION,
        "source_id": source_id,
        "frame_index": frame_index,
        "time_s": time_s,
        "equipment": {
            "deck": {
                "polygon": deck_polygon,
                "left": deck_left,
                "right": deck_right,
                "confidence": equipment_confidence,
            },
            "roller": {
                "left": roller_left,
                "right": roller_right,
                "confidence": equipment_confidence,
            },
        },
        "events": sorted(set(events or [])),
        "skill_labels": sorted(set(skill_labels or [])),
        "review": {
            "status": review_status,
            "model_id": model_id,
        },
    }
    validate_frame_annotation(payload)
    return payload


def _assign_grouped_splits(
    tasks: list[dict[str, Any]],
) -> None:
    groups = sorted(
        {str(task["split_group"]) for task in tasks}
    )
    split_by_group: dict[str, str] = {}

    for group in groups:
        digest = hashlib.sha256(group.encode("utf-8")).digest()
        bucket = int.from_bytes(digest[:2], "big") % 100
        if bucket < 70:
            split = "train"
        elif bucket < 85:
            split = "validation"
        else:
            split = "test"
        split_by_group[group] = split

    for task in tasks:
        task["split"] = split_by_group[
            str(task["split_group"])
        ]


def _priority(record: dict[str, Any]) -> int:
    labels = {
        str(value)
        for value in record.get("weak_labels", [])
        if str(value)
    }
    creator = str(record.get("creator") or "").lower()
    score = 0
    if "official" in labels or creator == "indoboard":
        score += 50
    if "tutorial" in labels or "fundamentals" in labels:
        score += 20
    if "trick-library" in labels or "tricks" in labels:
        score += 15
    if "beginner" in labels:
        score += 10
    if "community" in labels:
        score += 5
    return score


def _task_id(source_id: str) -> str:
    digest = hashlib.sha256(
        source_id.encode("utf-8")
    ).hexdigest()[:12]
    return f"indo-annotation/{digest}"


def _validate_deck(deck: object) -> None:
    if not isinstance(deck, dict):
        raise TypeError("equipment.deck must be an object")
    polygon = deck.get("polygon")
    if not isinstance(polygon, list) or len(polygon) < 4:
        raise ValueError("deck.polygon requires at least four points")
    for point in polygon:
        _validate_point(point, "deck.polygon")
    _validate_point(deck.get("left"), "deck.left")
    _validate_point(deck.get("right"), "deck.right")
    _validate_confidence(deck.get("confidence"), "deck.confidence")


def _validate_roller(roller: object) -> None:
    if not isinstance(roller, dict):
        raise TypeError("equipment.roller must be an object")
    _validate_point(roller.get("left"), "roller.left")
    _validate_point(roller.get("right"), "roller.right")
    _validate_confidence(
        roller.get("confidence"),
        "roller.confidence",
    )


def _validate_point(value: object, label: str) -> None:
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError(f"{label} must be [x, y]")
    for coordinate in value:
        if not isinstance(coordinate, (int, float)):
            raise TypeError(f"{label} coordinates must be numeric")
        if not 0 <= float(coordinate) <= 1:
            raise ValueError(
                f"{label} coordinates must be normalized to [0, 1]"
            )


def _validate_confidence(
    value: object,
    label: str,
) -> None:
    if not isinstance(value, (int, float)):
        raise TypeError(f"{label} must be numeric")
    if not 0 <= float(value) <= 1:
        raise ValueError(f"{label} must be in [0, 1]")


def _load_object(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def _write_json(
    path: str | Path,
    payload: dict[str, Any],
) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
