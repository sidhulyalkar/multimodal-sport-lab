from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .annotation_contract import (
    validate_annotation_manifest,
    validate_teacher_labels,
)
from .replay_review import REPLAY_REVIEW_QUEUE_SCHEMA_VERSION
from .video_alignment import file_sha256

REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION = (
    "motionos.replay-annotation-worklist.v1"
)


def _load_object(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def _load_jsonl(path: str | Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            text = raw.strip()
            if not text:
                continue
            value = json.loads(text)
            if not isinstance(value, dict):
                raise TypeError(
                    f"{path}:{line_number} must contain a JSON object"
                )
            rows.append(value)
    return rows


def _required_int(value: object, *, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{field} must be an integer")
    return value


def _required_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _field_names(value: object) -> list[str]:
    if not isinstance(value, dict):
        return []
    return sorted(str(key) for key in value)


def build_replay_annotation_worklist(
    queue_path: str | Path,
    manifest_path: str | Path,
    teacher_labels_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    """Bind replay-review windows to candidate teacher-label frames.

    The worklist is intentionally review-only. It does not modify teacher labels,
    change human-review state, or promote inferred/derived values to observations.
    """

    queue_file = Path(queue_path).resolve()
    manifest_file = Path(manifest_path).resolve()
    labels_file = Path(teacher_labels_path).resolve()

    queue = _load_object(queue_file)
    if queue.get("schema_version") != REPLAY_REVIEW_QUEUE_SCHEMA_VERSION:
        raise ValueError("unsupported replay review queue schema")

    manifest = validate_annotation_manifest(manifest_file)
    validation = validate_teacher_labels(labels_file, manifest_file)

    run_id = _required_string(queue.get("run_id"), field="queue.run_id")
    if manifest.get("run_id") != run_id:
        raise ValueError("review queue/annotation manifest run_id mismatch")

    alignment = queue.get("alignment")
    manifest_alignment = manifest.get("video_alignment")
    manifest_source = manifest.get("source_video")
    if not isinstance(alignment, dict):
        raise TypeError("review queue alignment must be an object")
    if not isinstance(manifest_alignment, dict):
        raise TypeError("annotation manifest video_alignment is malformed")
    if not isinstance(manifest_source, dict):
        raise TypeError("annotation manifest source_video is malformed")

    queue_alignment_sha = _required_string(
        alignment.get("sha256"),
        field="queue.alignment.sha256",
    )
    manifest_alignment_sha = _required_string(
        manifest_alignment.get("sha256"),
        field="manifest.video_alignment.sha256",
    )
    if queue_alignment_sha != manifest_alignment_sha:
        raise ValueError("review queue/annotation alignment hash mismatch")

    queue_source_sha = _required_string(
        alignment.get("source_video_sha256"),
        field="queue.alignment.source_video_sha256",
    )
    manifest_source_sha = _required_string(
        manifest_source.get("sha256"),
        field="manifest.source_video.sha256",
    )
    if queue_source_sha != manifest_source_sha:
        raise ValueError("review queue/annotation source-video hash mismatch")

    tasks = queue.get("tasks")
    if not isinstance(tasks, list):
        raise TypeError("review queue tasks must be a list")
    declared_task_count = _required_int(
        queue.get("task_count"),
        field="queue.task_count",
    )
    if declared_task_count != len(tasks):
        raise ValueError("review queue task_count mismatch")

    labels = _load_jsonl(labels_file)
    if len(labels) != validation.label_count:
        raise ValueError("teacher-label count changed during worklist build")

    candidate_frames: list[dict[str, Any]] = []
    work_items: list[dict[str, Any]] = []
    candidate_ids: set[str] = set()
    uncovered_tasks = 0

    for task_index, task in enumerate(tasks):
        if not isinstance(task, dict):
            raise TypeError(f"queue.tasks[{task_index}] must be an object")

        task_id = _required_string(
            task.get("task_id"),
            field=f"queue.tasks[{task_index}].task_id",
        )
        flag_id = _required_string(
            task.get("flag_id"),
            field=f"queue.tasks[{task_index}].flag_id",
        )
        window = task.get("reference_window")
        if not isinstance(window, dict):
            raise TypeError(
                f"queue.tasks[{task_index}].reference_window must be an object"
            )
        start_ns = _required_int(
            window.get("start_ns"),
            field=f"queue.tasks[{task_index}].reference_window.start_ns",
        )
        end_ns = _required_int(
            window.get("end_ns"),
            field=f"queue.tasks[{task_index}].reference_window.end_ns",
        )
        if end_ns <= start_ns:
            raise ValueError(f"review task {task_id!r} has an empty window")

        matching_ids: list[str] = []
        for label_index, label in enumerate(labels):
            reference_time_ns = _required_int(
                label.get("reference_time_ns"),
                field=f"labels[{label_index}].reference_time_ns",
            )
            if not start_ns <= reference_time_ns <= end_ns:
                continue

            source_pts_ns = _required_int(
                label.get("source_frame_pts_ns"),
                field=f"labels[{label_index}].source_frame_pts_ns",
            )
            frame_id = (
                f"teacher-frame/{source_pts_ns:020d}/"
                f"{reference_time_ns:020d}"
            )
            matching_ids.append(frame_id)

            if frame_id not in candidate_ids:
                candidate_ids.add(frame_id)
                candidate_frames.append(
                    {
                        "candidate_id": frame_id,
                        "label_index": label_index,
                        "source_frame_pts_ns": source_pts_ns,
                        "reference_time_ns": reference_time_ns,
                        "human_review_state": label.get(
                            "human_review_state"
                        ),
                        "observed_fields": _field_names(
                            label.get("observed")
                        ),
                        "derived_fields": _field_names(
                            label.get("derived")
                        ),
                        "inferred_fields": _field_names(
                            label.get("inferred")
                        ),
                        "model_versions": label.get("model_versions", {}),
                    }
                )

        if not matching_ids:
            uncovered_tasks += 1

        work_items.append(
            {
                "task_id": task_id,
                "flag_id": flag_id,
                "scope": task.get("scope"),
                "verdict": task.get("verdict"),
                "note": str(task.get("note") or ""),
                "reference_window": {
                    "start_ns": start_ns,
                    "end_ns": end_ns,
                },
                "action4_source_window": task.get(
                    "action4_source_window"
                ),
                "candidate_ids": matching_ids,
                "candidate_count": len(matching_ids),
                "coverage_status": (
                    "teacher_labels_available"
                    if matching_ids
                    else "video_review_only"
                ),
                "evidence_state": task.get("evidence_state", {}),
            }
        )

    queue_sha256, queue_bytes = file_sha256(queue_file)
    manifest_sha256, manifest_bytes = file_sha256(manifest_file)
    labels_sha256, labels_bytes = file_sha256(labels_file)

    payload: dict[str, Any] = {
        "schema_version": REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
        "run_id": run_id,
        "bindings": {
            "replay_review_queue": {
                "path": str(queue_file),
                "sha256": queue_sha256,
                "byte_count": queue_bytes,
            },
            "annotation_manifest": {
                "path": str(manifest_file),
                "sha256": manifest_sha256,
                "byte_count": manifest_bytes,
            },
            "teacher_labels": {
                "path": str(labels_file),
                "sha256": labels_sha256,
                "byte_count": labels_bytes,
            },
            "video_alignment_sha256": queue_alignment_sha,
            "source_video_sha256": queue_source_sha,
        },
        "summary": {
            "review_task_count": len(work_items),
            "candidate_frame_count": len(candidate_frames),
            "video_only_task_count": uncovered_tasks,
            "validated_teacher_label_count": validation.label_count,
        },
        "work_items": work_items,
        "candidate_frames": candidate_frames,
        "claim_boundary": (
            "This worklist binds human replay-review windows to already-"
            "validated teacher-label candidates. It does not alter review "
            "state, create human corrections, or convert derived/inferred "
            "model output into observed biomechanics ground truth."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
