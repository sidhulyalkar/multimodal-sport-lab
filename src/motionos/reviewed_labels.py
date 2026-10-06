from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
from typing import Any

from .annotation_contract import validate_teacher_labels
from .human_corrections import HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION
from .video_alignment import file_sha256

REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION = (
    "motionos.reviewed-labels-receipt.v1"
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


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _required_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def materialize_reviewed_labels(
    receipt_path: str | Path,
    teacher_labels_path: str | Path,
    manifest_path: str | Path,
    output_labels_path: str | Path,
    output_receipt_path: str | Path,
) -> dict[str, Any]:
    """Create a reviewed label stream without modifying teacher labels."""

    receipt_file = Path(receipt_path).resolve()
    source_labels_file = Path(teacher_labels_path).resolve()
    manifest_file = Path(manifest_path).resolve()

    receipt = _load_object(receipt_file)
    if receipt.get("schema_version") != HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION:
        raise ValueError("unsupported human correction receipt schema")

    bindings = receipt.get("bindings")
    if not isinstance(bindings, dict):
        raise TypeError("human correction receipt bindings must be an object")
    label_binding = bindings.get("teacher_labels")
    if not isinstance(label_binding, dict):
        raise TypeError("human correction teacher_labels binding is malformed")

    source_labels_sha, source_labels_bytes = file_sha256(source_labels_file)
    expected_labels_sha = _required_string(
        label_binding.get("sha256"),
        field="receipt.bindings.teacher_labels.sha256",
    )
    if source_labels_sha != expected_labels_sha:
        raise ValueError("teacher-label hash does not match correction receipt")

    source_validation = validate_teacher_labels(
        source_labels_file,
        manifest_file,
    )
    rows = _load_jsonl(source_labels_file)
    if len(rows) != source_validation.label_count:
        raise ValueError("teacher-label count changed during materialization")

    reviewed = copy.deepcopy(rows)
    decisions = receipt.get("decisions")
    if not isinstance(decisions, list):
        raise TypeError("human correction receipt decisions must be a list")

    receipt_sha, receipt_bytes = file_sha256(receipt_file)
    seen_decision_ids: set[str] = set()
    seen_label_indexes: set[int] = set()

    counts = {
        "accepted": 0,
        "corrected": 0,
        "rejected": 0,
        "reviewed": 0,
    }
    corrected_field_count = 0

    for index, decision in enumerate(decisions):
        if not isinstance(decision, dict):
            raise TypeError(f"receipt.decisions[{index}] must be an object")

        decision_id = _required_string(
            decision.get("decision_id"),
            field=f"receipt.decisions[{index}].decision_id",
        )
        if decision_id in seen_decision_ids:
            raise ValueError(f"duplicate correction decision_id: {decision_id}")
        seen_decision_ids.add(decision_id)

        label_index = decision.get("label_index")
        if isinstance(label_index, bool) or not isinstance(label_index, int):
            raise TypeError(
                f"receipt.decisions[{index}].label_index must be an integer"
            )
        if not 0 <= label_index < len(rows):
            raise ValueError("correction label_index is outside teacher labels")
        if label_index in seen_label_indexes:
            raise ValueError(
                f"teacher label {label_index} has multiple review decisions"
            )
        seen_label_indexes.add(label_index)

        source_row = rows[label_index]
        expected_row_sha = _required_string(
            decision.get("original_label_sha256"),
            field=(
                f"receipt.decisions[{index}].original_label_sha256"
            ),
        )
        if _canonical_sha256(source_row) != expected_row_sha:
            raise ValueError(
                f"teacher label {label_index} no longer matches decision"
            )

        if (
            source_row.get("source_frame_pts_ns")
            != decision.get("source_frame_pts_ns")
        ):
            raise ValueError("review decision source PTS mismatch")
        if (
            source_row.get("reference_time_ns")
            != decision.get("reference_time_ns")
        ):
            raise ValueError("review decision reference time mismatch")

        target_state = _required_string(
            decision.get("target_human_review_state"),
            field=(
                f"receipt.decisions[{index}].target_human_review_state"
            ),
        )
        if target_state not in {"accepted", "rejected", "reviewed"}:
            raise ValueError(
                f"unsupported target human review state: {target_state}"
            )

        disposition = _required_string(
            decision.get("disposition"),
            field=f"receipt.decisions[{index}].disposition",
        )
        row = reviewed[label_index]

        after = decision.get("after", {})
        if not isinstance(after, dict):
            raise TypeError(f"receipt.decisions[{index}].after must be an object")

        corrected_fields: list[str] = []
        if disposition == "corrected":
            if not after:
                raise ValueError("corrected decision has no corrected values")
            for evidence_class, patch in after.items():
                if evidence_class not in {"observed", "derived", "inferred"}:
                    raise ValueError(
                        f"unsupported corrected evidence class: {evidence_class}"
                    )
                if not isinstance(patch, dict) or not patch:
                    raise ValueError(
                        "corrected evidence patch must be a non-empty object"
                    )
                target = row.get(evidence_class)
                if not isinstance(target, dict):
                    raise TypeError(
                        f"teacher label {evidence_class} must be an object"
                    )
                for field, value in patch.items():
                    if field not in target:
                        raise ValueError(
                            f"correction field disappeared from source: {field}"
                        )
                    target[field] = value
                    corrected_fields.append(
                        f"{evidence_class}.{field}"
                    )

                    confidence = row.get("confidence")
                    if isinstance(confidence, dict):
                        confidence.pop(field, None)
            counts["corrected"] += 1
            corrected_field_count += len(corrected_fields)
        elif after:
            raise ValueError(
                f"{disposition} decision unexpectedly contains corrections"
            )

        row["human_review_state"] = target_state
        if target_state == "accepted":
            counts["accepted"] += 1
        elif target_state == "rejected":
            counts["rejected"] += 1
        else:
            counts["reviewed"] += 1

        row["human_review_provenance"] = {
            "correction_receipt_sha256": receipt_sha,
            "decision_id": decision_id,
            "disposition": disposition,
            "corrected_fields": corrected_fields,
            "note": str(decision.get("note") or ""),
        }

    output_labels = Path(output_labels_path)
    output_labels.parent.mkdir(parents=True, exist_ok=True)
    output_labels.write_text(
        "".join(
            json.dumps(row, sort_keys=True) + "\n"
            for row in reviewed
        ),
        encoding="utf-8",
    )

    reviewed_validation = validate_teacher_labels(
        output_labels,
        manifest_file,
    )
    output_sha, output_bytes = file_sha256(output_labels)
    manifest_sha, manifest_bytes = file_sha256(manifest_file)

    materialization_receipt: dict[str, Any] = {
        "schema_version": REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION,
        "run_id": receipt.get("run_id"),
        "bindings": {
            "human_correction_receipt": {
                "path": str(receipt_file),
                "sha256": receipt_sha,
                "byte_count": receipt_bytes,
            },
            "source_teacher_labels": {
                "path": str(source_labels_file),
                "sha256": source_labels_sha,
                "byte_count": source_labels_bytes,
            },
            "annotation_manifest": {
                "path": str(manifest_file),
                "sha256": manifest_sha,
                "byte_count": manifest_bytes,
            },
            "reviewed_labels": {
                "path": str(output_labels.resolve()),
                "sha256": output_sha,
                "byte_count": output_bytes,
            },
        },
        "summary": {
            "source_label_count": len(rows),
            "review_decision_count": len(decisions),
            "accepted_count": counts["accepted"],
            "corrected_decision_count": counts["corrected"],
            "corrected_field_count": corrected_field_count,
            "rejected_count": counts["rejected"],
            "insufficient_evidence_count": counts["reviewed"],
            "validated_reviewed_label_count": (
                reviewed_validation.label_count
            ),
        },
        "claim_boundary": (
            "Reviewed labels are a non-destructive derivative of the original "
            "teacher-label stream plus an explicit human correction receipt. "
            "Human corrections preserve evidence classes and do not establish "
            "metric biomechanics truth or runtime model qualification."
        ),
    }

    output_receipt = Path(output_receipt_path)
    output_receipt.parent.mkdir(parents=True, exist_ok=True)
    output_receipt.write_text(
        json.dumps(
            materialization_receipt,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return materialization_receipt
