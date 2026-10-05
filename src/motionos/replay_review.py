from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .video_alignment import file_sha256, load_video_alignment

REPLAY_REVIEW_LEDGER_SCHEMA_VERSION = "motionos.replay-review-ledger.v1"
REPLAY_REVIEW_FLAG_SCHEMA_VERSION = "motionos.replay-review-flag.v1"
REPLAY_REVIEW_QUEUE_SCHEMA_VERSION = "motionos.replay-review-queue.v1"

_ALLOWED_SCOPES = {
    "timing",
    "iphone_pose",
    "action4_pose",
    "equipment",
    "behavior",
    "coaching",
    "other",
}
_ALLOWED_VERDICTS = {
    "inspect",
    "wrong",
    "good_example",
    "occluded",
}


def _load_object(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def _nonempty_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _integer(value: object, *, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{field} must be an integer")
    return value


def _artifact_bindings(
    flag: dict[str, Any],
    *,
    index: int,
) -> dict[str, dict[str, Any]]:
    raw = flag.get("artifact_bindings")
    if not isinstance(raw, list):
        raise TypeError(
            f"flags[{index}].artifact_bindings must be a list"
        )

    bindings: dict[str, dict[str, Any]] = {}
    for binding_index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(
                f"flags[{index}].artifact_bindings[{binding_index}] "
                "must be an object"
            )
        role = _nonempty_string(
            item.get("role"),
            field=(
                f"flags[{index}].artifact_bindings"
                f"[{binding_index}].role"
            ),
        )
        sha256 = _nonempty_string(
            item.get("sha256"),
            field=(
                f"flags[{index}].artifact_bindings"
                f"[{binding_index}].sha256"
            ),
        )
        if role in bindings:
            raise ValueError(
                f"flags[{index}] contains duplicate artifact role {role!r}"
            )
        bindings[role] = {
            "role": role,
            "sha256": sha256,
            "filename": item.get("filename"),
        }
    return bindings


def validate_replay_review_ledger(
    ledger_path: str | Path,
    alignment_path: str | Path,
) -> tuple[dict[str, Any], Any, str]:
    ledger = _load_object(ledger_path)
    if ledger.get("schema_version") != REPLAY_REVIEW_LEDGER_SCHEMA_VERSION:
        raise ValueError("unsupported replay review ledger schema")

    run_id = _nonempty_string(ledger.get("run_id"), field="run_id")
    flags = ledger.get("flags")
    if not isinstance(flags, list):
        raise TypeError("replay review ledger flags must be a list")

    alignment = load_video_alignment(alignment_path)
    if alignment.run_id != run_id:
        raise ValueError("replay review ledger/alignment run_id mismatch")

    alignment_sha256, _ = file_sha256(alignment_path)

    previous_reference: int | None = None
    seen_ids: set[str] = set()
    for index, flag in enumerate(flags):
        if not isinstance(flag, dict):
            raise TypeError(f"flags[{index}] must be an object")
        if flag.get("schema_version") != REPLAY_REVIEW_FLAG_SCHEMA_VERSION:
            raise ValueError(
                f"flags[{index}] has unsupported schema version"
            )
        flag_id = _nonempty_string(
            flag.get("id"),
            field=f"flags[{index}].id",
        )
        if flag_id in seen_ids:
            raise ValueError(f"duplicate replay review flag id: {flag_id}")
        seen_ids.add(flag_id)

        if flag.get("run_id") != run_id:
            raise ValueError(f"flags[{index}] run_id mismatch")

        reference_time_ns = _integer(
            flag.get("reference_time_ns"),
            field=f"flags[{index}].reference_time_ns",
        )
        if reference_time_ns < 0:
            raise ValueError("review reference time cannot be negative")
        if (
            previous_reference is not None
            and reference_time_ns < previous_reference
        ):
            raise ValueError(
                "replay review flags must be ordered by reference time"
            )
        previous_reference = reference_time_ns

        scope = flag.get("scope")
        if scope not in _ALLOWED_SCOPES:
            raise ValueError(f"flags[{index}] has unsupported scope")
        verdict = flag.get("verdict")
        if verdict not in _ALLOWED_VERDICTS:
            raise ValueError(f"flags[{index}] has unsupported verdict")

        before_ns = _integer(
            flag.get("window_before_ns"),
            field=f"flags[{index}].window_before_ns",
        )
        after_ns = _integer(
            flag.get("window_after_ns"),
            field=f"flags[{index}].window_after_ns",
        )
        if before_ns < 0 or after_ns < 0:
            raise ValueError("review windows cannot be negative")

        bindings = _artifact_bindings(flag, index=index)
        alignment_binding = bindings.get("video_alignment")
        if alignment_binding is None:
            raise ValueError(
                f"flags[{index}] is not bound to video_alignment"
            )
        if alignment_binding["sha256"] != alignment_sha256:
            raise ValueError(
                f"flags[{index}] video_alignment hash mismatch"
            )

        action4_binding = bindings.get("action4_video")
        if action4_binding is None:
            raise ValueError(
                f"flags[{index}] is not bound to action4_video"
            )
        if (
            action4_binding["sha256"]
            != alignment.source_video_sha256
        ):
            raise ValueError(
                f"flags[{index}] Action 4 source hash mismatch"
            )

        stored_pts = flag.get("action4_video_pts_ns")
        if stored_pts is None:
            raise ValueError(
                f"flags[{index}] is missing mapped Action 4 PTS"
            )
        stored_pts_int = _integer(
            stored_pts,
            field=f"flags[{index}].action4_video_pts_ns",
        )
        expected_pts = alignment.map_reference_to_video_pts(
            reference_time_ns
        )
        if expected_pts != stored_pts_int:
            raise ValueError(
                f"flags[{index}] Action 4 PTS does not recompute"
            )
        if not 0 <= stored_pts_int <= alignment.video_duration_ns:
            raise ValueError(
                f"flags[{index}] Action 4 PTS lies outside source video"
            )

    return ledger, alignment, alignment_sha256


def _playable_reference_window(alignment: Any) -> tuple[int, int]:
    source_start_reference = alignment.map_video_pts_to_reference(0)
    source_end_reference = alignment.map_video_pts_to_reference(
        alignment.video_duration_ns
    )
    start_ns = max(
        alignment.reference_start_ns,
        source_start_reference,
    )
    end_ns = min(
        alignment.reference_end_ns,
        source_end_reference,
    )
    if end_ns <= start_ns:
        raise ValueError("alignment has no shared playable reference window")
    return start_ns, end_ns


def build_replay_review_queue(
    ledger_path: str | Path,
    alignment_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    ledger, alignment, alignment_sha256 = (
        validate_replay_review_ledger(
            ledger_path,
            alignment_path,
        )
    )
    playable_start_ns, playable_end_ns = _playable_reference_window(
        alignment
    )

    tasks: list[dict[str, Any]] = []
    for flag in ledger["flags"]:
        reference_time_ns = int(flag["reference_time_ns"])
        before_ns = int(flag["window_before_ns"])
        after_ns = int(flag["window_after_ns"])

        reference_start_ns = max(
            playable_start_ns,
            reference_time_ns - before_ns,
        )
        reference_end_ns = min(
            playable_end_ns,
            reference_time_ns + after_ns,
        )
        if reference_end_ns <= reference_start_ns:
            raise ValueError(
                f"review flag {flag['id']!r} has no playable window"
            )

        source_start_ns = alignment.map_reference_to_video_pts(
            reference_start_ns
        )
        source_end_ns = alignment.map_reference_to_video_pts(
            reference_end_ns
        )
        source_start_ns = max(
            0,
            min(alignment.video_duration_ns, source_start_ns),
        )
        source_end_ns = max(
            0,
            min(alignment.video_duration_ns, source_end_ns),
        )
        if source_end_ns <= source_start_ns:
            raise ValueError(
                f"review flag {flag['id']!r} maps to an empty source window"
            )

        tasks.append(
            {
                "task_id": f"replay-review/{flag['id']}",
                "flag_id": flag["id"],
                "scope": flag["scope"],
                "verdict": flag["verdict"],
                "note": str(flag.get("note") or ""),
                "reference_time_ns": reference_time_ns,
                "action4_video_pts_ns": int(
                    flag["action4_video_pts_ns"]
                ),
                "reference_window": {
                    "start_ns": reference_start_ns,
                    "end_ns": reference_end_ns,
                },
                "action4_source_window": {
                    "start_pts_ns": source_start_ns,
                    "end_pts_ns": source_end_ns,
                },
                "evidence_state": {
                    "iphone_pose_available": bool(
                        flag.get("iphone_pose_available", False)
                    ),
                    "action4_pose_available": bool(
                        flag.get("action4_pose_available", False)
                    ),
                    "equipment_available": bool(
                        flag.get("equipment_available", False)
                    ),
                    "observed_playback_drift_ms": flag.get(
                        "observed_playback_drift_ms"
                    ),
                },
                "artifact_bindings": list(
                    flag.get("artifact_bindings", [])
                ),
            }
        )

    payload = {
        "schema_version": REPLAY_REVIEW_QUEUE_SCHEMA_VERSION,
        "run_id": ledger["run_id"],
        "alignment": {
            "sha256": alignment_sha256,
            "source_video_sha256": alignment.source_video_sha256,
            "source_video_filename": alignment.source_video_filename,
            "playable_reference_start_ns": playable_start_ns,
            "playable_reference_end_ns": playable_end_ns,
        },
        "task_count": len(tasks),
        "tasks": tasks,
        "claim_boundary": (
            "This queue converts evidence-bound human replay flags into exact "
            "reference/video windows for QA and annotation. It does not turn "
            "human review markers into metric biomechanics ground truth or "
            "authorize an unqualified model for runtime use."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
