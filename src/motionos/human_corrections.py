from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .replay_annotation import REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION
from .video_alignment import file_sha256

HUMAN_CORRECTION_SPEC_SCHEMA_VERSION = "motionos.human-correction-spec.v1"
HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION = (
    "motionos.human-correction-receipt.v1"
)

_ALLOWED_DISPOSITIONS = {
    "accept_existing",
    "corrected",
    "rejected",
    "insufficient_evidence",
}
_EVIDENCE_CLASSES = ("observed", "derived", "inferred")


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
            try:
                value = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"{path}:{line_number} is invalid JSON"
                ) from exc
            if not isinstance(value, dict):
                raise TypeError(
                    f"{path}:{line_number} must contain a JSON object"
                )
            rows.append(value)
    return rows


def _required_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _candidate_map(
    worklist: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    raw = worklist.get("candidate_frames")
    if not isinstance(raw, list):
        raise TypeError("worklist candidate_frames must be a list")

    result: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(
                f"worklist candidate_frames[{index}] must be an object"
            )
        candidate_id = _required_string(
            item.get("candidate_id"),
            field=f"candidate_frames[{index}].candidate_id",
        )
        if candidate_id in result:
            raise ValueError(f"duplicate candidate_id: {candidate_id}")
        result[candidate_id] = item
    return result


def _task_membership(
    worklist: dict[str, Any],
) -> dict[str, set[str]]:
    raw = worklist.get("work_items")
    if not isinstance(raw, list):
        raise TypeError("worklist work_items must be a list")

    membership: dict[str, set[str]] = {}
    seen_tasks: set[str] = set()
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(
                f"worklist work_items[{index}] must be an object"
            )
        task_id = _required_string(
            item.get("task_id"),
            field=f"work_items[{index}].task_id",
        )
        if task_id in seen_tasks:
            raise ValueError(f"duplicate worklist task_id: {task_id}")
        seen_tasks.add(task_id)

        candidate_ids = item.get("candidate_ids")
        if not isinstance(candidate_ids, list):
            raise TypeError(
                f"work_items[{index}].candidate_ids must be a list"
            )
        for candidate_index, raw_candidate_id in enumerate(candidate_ids):
            candidate_id = _required_string(
                raw_candidate_id,
                field=(
                    f"work_items[{index}].candidate_ids"
                    f"[{candidate_index}]"
                ),
            )
            membership.setdefault(candidate_id, set()).add(task_id)
    return membership


def _label_for_candidate(
    candidate: dict[str, Any],
    labels: list[dict[str, Any]],
) -> dict[str, Any]:
    label_index = candidate.get("label_index")
    if isinstance(label_index, bool) or not isinstance(label_index, int):
        raise TypeError("candidate label_index must be an integer")
    if not 0 <= label_index < len(labels):
        raise ValueError("candidate label_index is outside teacher labels")

    label = labels[label_index]
    expected_pts = candidate.get("source_frame_pts_ns")
    expected_reference = candidate.get("reference_time_ns")
    if label.get("source_frame_pts_ns") != expected_pts:
        raise ValueError("candidate source PTS no longer matches teacher label")
    if label.get("reference_time_ns") != expected_reference:
        raise ValueError(
            "candidate reference time no longer matches teacher label"
        )
    return label


def _validate_corrections(
    raw: object,
    *,
    label: dict[str, Any],
    decision_index: int,
) -> dict[str, dict[str, Any]]:
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise TypeError(
            f"decisions[{decision_index}].corrections must be an object"
        )

    unknown_classes = sorted(set(raw) - set(_EVIDENCE_CLASSES))
    if unknown_classes:
        raise ValueError(
            "unsupported correction evidence classes: "
            + ", ".join(unknown_classes)
        )

    corrections: dict[str, dict[str, Any]] = {}
    for evidence_class in _EVIDENCE_CLASSES:
        patch = raw.get(evidence_class, {})
        if not isinstance(patch, dict):
            raise TypeError(
                f"decisions[{decision_index}].corrections."
                f"{evidence_class} must be an object"
            )
        source = label.get(evidence_class, {})
        if not isinstance(source, dict):
            raise TypeError(
                f"teacher label {evidence_class} must be an object"
            )

        unknown_fields = sorted(set(patch) - set(source))
        if unknown_fields:
            raise ValueError(
                f"{evidence_class} correction introduces unknown fields: "
                + ", ".join(unknown_fields)
            )
        corrections[evidence_class] = {
            str(key): value
            for key, value in patch.items()
        }
    return corrections


def build_human_correction_receipt(
    spec_path: str | Path,
    worklist_path: str | Path,
    teacher_labels_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    """Build an immutable receipt of explicit human review decisions.

    This function never mutates teacher labels. Corrections remain in the same
    observed/derived/inferred evidence class as the source field.
    """

    spec_file = Path(spec_path).resolve()
    worklist_file = Path(worklist_path).resolve()
    labels_file = Path(teacher_labels_path).resolve()

    spec = _load_object(spec_file)
    if spec.get("schema_version") != HUMAN_CORRECTION_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported human correction spec schema")

    worklist = _load_object(worklist_file)
    if (
        worklist.get("schema_version")
        != REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION
    ):
        raise ValueError("unsupported replay annotation worklist schema")

    run_id = _required_string(spec.get("run_id"), field="spec.run_id")
    if worklist.get("run_id") != run_id:
        raise ValueError("correction spec/worklist run_id mismatch")

    worklist_sha256, worklist_bytes = file_sha256(worklist_file)
    spec_worklist_sha = _required_string(
        spec.get("worklist_sha256"),
        field="spec.worklist_sha256",
    )
    if spec_worklist_sha != worklist_sha256:
        raise ValueError("correction spec worklist hash mismatch")

    bindings = worklist.get("bindings")
    if not isinstance(bindings, dict):
        raise TypeError("worklist bindings must be an object")
    label_binding = bindings.get("teacher_labels")
    if not isinstance(label_binding, dict):
        raise TypeError("worklist teacher_labels binding is malformed")

    labels_sha256, labels_bytes = file_sha256(labels_file)
    expected_labels_sha = _required_string(
        label_binding.get("sha256"),
        field="worklist.bindings.teacher_labels.sha256",
    )
    if labels_sha256 != expected_labels_sha:
        raise ValueError("teacher-label hash does not match worklist binding")

    labels = _load_jsonl(labels_file)
    candidates = _candidate_map(worklist)
    membership = _task_membership(worklist)

    reviewer = spec.get("reviewer")
    if not isinstance(reviewer, dict):
        raise TypeError("spec.reviewer must be an object")
    reviewer_kind = _required_string(
        reviewer.get("kind"),
        field="spec.reviewer.kind",
    )
    if reviewer_kind != "human":
        raise ValueError("correction reviewer.kind must be 'human'")
    reviewer_id = reviewer.get("id")
    if reviewer_id is not None:
        reviewer_id = _required_string(
            reviewer_id,
            field="spec.reviewer.id",
        )

    raw_decisions = spec.get("decisions")
    if not isinstance(raw_decisions, list) or not raw_decisions:
        raise ValueError("correction spec requires at least one decision")

    seen_candidates: set[str] = set()
    decisions: list[dict[str, Any]] = []
    counts = {name: 0 for name in sorted(_ALLOWED_DISPOSITIONS)}

    for index, raw in enumerate(raw_decisions):
        if not isinstance(raw, dict):
            raise TypeError(f"decisions[{index}] must be an object")

        task_id = _required_string(
            raw.get("task_id"),
            field=f"decisions[{index}].task_id",
        )
        candidate_id = _required_string(
            raw.get("candidate_id"),
            field=f"decisions[{index}].candidate_id",
        )
        if candidate_id in seen_candidates:
            raise ValueError(
                f"candidate reviewed more than once: {candidate_id}"
            )
        seen_candidates.add(candidate_id)

        candidate = candidates.get(candidate_id)
        if candidate is None:
            raise ValueError(f"unknown correction candidate: {candidate_id}")
        if task_id not in membership.get(candidate_id, set()):
            raise ValueError(
                f"candidate {candidate_id!r} does not belong to task "
                f"{task_id!r}"
            )

        disposition = _required_string(
            raw.get("disposition"),
            field=f"decisions[{index}].disposition",
        )
        if disposition not in _ALLOWED_DISPOSITIONS:
            raise ValueError(
                f"unsupported correction disposition: {disposition}"
            )

        label = _label_for_candidate(candidate, labels)
        corrections = _validate_corrections(
            raw.get("corrections", {}),
            label=label,
            decision_index=index,
        )
        correction_count = sum(
            len(patch)
            for patch in corrections.values()
        )
        if disposition == "corrected" and correction_count == 0:
            raise ValueError(
                "corrected disposition requires at least one field correction"
            )
        if disposition != "corrected" and correction_count:
            raise ValueError(
                f"{disposition} disposition cannot contain field corrections"
            )

        before: dict[str, dict[str, Any]] = {}
        after: dict[str, dict[str, Any]] = {}
        if disposition == "corrected":
            for evidence_class, patch in corrections.items():
                if not patch:
                    continue
                source = label[evidence_class]
                before[evidence_class] = {
                    key: source[key]
                    for key in patch
                }
                after[evidence_class] = dict(patch)

        target_review_state = {
            "accept_existing": "accepted",
            "corrected": "accepted",
            "rejected": "rejected",
            "insufficient_evidence": "reviewed",
        }[disposition]

        decision_payload = {
            "task_id": task_id,
            "candidate_id": candidate_id,
            "disposition": disposition,
            "target_human_review_state": target_review_state,
            "note": str(raw.get("note") or ""),
            "label_index": candidate["label_index"],
            "source_frame_pts_ns": candidate["source_frame_pts_ns"],
            "reference_time_ns": candidate["reference_time_ns"],
            "original_label_sha256": _canonical_sha256(label),
            "before": before,
            "after": after,
        }
        decision_payload["decision_id"] = (
            "human-review/"
            + _canonical_sha256(decision_payload)[:24]
        )
        decisions.append(decision_payload)
        counts[disposition] += 1

    spec_sha256, spec_bytes = file_sha256(spec_file)

    payload: dict[str, Any] = {
        "schema_version": HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION,
        "run_id": run_id,
        "reviewer": {
            "kind": reviewer_kind,
            "id": reviewer_id,
        },
        "bindings": {
            "correction_spec": {
                "path": str(spec_file),
                "sha256": spec_sha256,
                "byte_count": spec_bytes,
            },
            "replay_annotation_worklist": {
                "path": str(worklist_file),
                "sha256": worklist_sha256,
                "byte_count": worklist_bytes,
            },
            "teacher_labels": {
                "path": str(labels_file),
                "sha256": labels_sha256,
                "byte_count": labels_bytes,
            },
        },
        "summary": {
            "decision_count": len(decisions),
            "accept_existing_count": counts["accept_existing"],
            "corrected_count": counts["corrected"],
            "rejected_count": counts["rejected"],
            "insufficient_evidence_count": counts[
                "insufficient_evidence"
            ],
        },
        "decisions": decisions,
        "claim_boundary": (
            "This receipt records explicit human review decisions against "
            "hash-bound teacher-label candidates. Corrections stay in the "
            "same observed/derived/inferred evidence class as the source "
            "field. The receipt does not mutate raw labels, establish metric "
            "biomechanics truth, or qualify a model for runtime use."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
