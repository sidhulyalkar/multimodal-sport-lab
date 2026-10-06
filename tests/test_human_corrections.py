from __future__ import annotations

import json

import pytest

from motionos.human_corrections import (
    HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION,
    HUMAN_CORRECTION_SPEC_SCHEMA_VERSION,
    build_human_correction_receipt,
)
from motionos.replay_annotation import (
    REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
)
from motionos.video_alignment import file_sha256


def _fixture(tmp_path):
    labels = [
        {
            "schema_version": "motionos.teacher-label.v1",
            "annotation_manifest_sha256": "a" * 64,
            "run_id": "run-1",
            "sport": "indo_board",
            "source_video_sha256": "b" * 64,
            "source_frame_pts_ns": 5_000_000_000,
            "reference_time_ns": 5_000_000_000,
            "observed": {
                "body_pose_visible": True,
                "board_visible": True,
            },
            "derived": {
                "pelvis_offset_m": 0.04,
                "roller_along_deck": 0.10,
            },
            "inferred": {
                "movement_primitive": "neutral_balance",
            },
            "confidence": {
                "body_pose_visible": 0.95,
            },
            "model_versions": {
                "pose": "fixture",
            },
            "human_review_state": "unreviewed",
        },
        {
            "schema_version": "motionos.teacher-label.v1",
            "annotation_manifest_sha256": "a" * 64,
            "run_id": "run-1",
            "sport": "indo_board",
            "source_video_sha256": "b" * 64,
            "source_frame_pts_ns": 6_000_000_000,
            "reference_time_ns": 6_000_000_000,
            "observed": {
                "body_pose_visible": True,
                "board_visible": True,
            },
            "derived": {
                "pelvis_offset_m": 0.02,
                "roller_along_deck": 0.05,
            },
            "inferred": {
                "movement_primitive": "neutral_balance",
            },
            "confidence": {
                "body_pose_visible": 0.96,
            },
            "model_versions": {
                "pose": "fixture",
            },
            "human_review_state": "unreviewed",
        },
    ]
    labels_path = tmp_path / "teacher-labels.jsonl"
    labels_path.write_text(
        "".join(json.dumps(row) + "\n" for row in labels),
        encoding="utf-8",
    )
    labels_sha, labels_bytes = file_sha256(labels_path)

    candidate_a = "teacher-frame/00000000005000000000/00000000005000000000"
    candidate_b = "teacher-frame/00000000006000000000/00000000006000000000"
    worklist = {
        "schema_version": REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
        "run_id": "run-1",
        "bindings": {
            "teacher_labels": {
                "path": str(labels_path),
                "sha256": labels_sha,
                "byte_count": labels_bytes,
            },
        },
        "summary": {
            "review_task_count": 1,
            "candidate_frame_count": 2,
            "video_only_task_count": 0,
            "validated_teacher_label_count": 2,
        },
        "work_items": [
            {
                "task_id": "replay-review/flag-1",
                "flag_id": "flag-1",
                "candidate_ids": [candidate_a, candidate_b],
                "candidate_count": 2,
            }
        ],
        "candidate_frames": [
            {
                "candidate_id": candidate_a,
                "label_index": 0,
                "source_frame_pts_ns": 5_000_000_000,
                "reference_time_ns": 5_000_000_000,
                "human_review_state": "unreviewed",
            },
            {
                "candidate_id": candidate_b,
                "label_index": 1,
                "source_frame_pts_ns": 6_000_000_000,
                "reference_time_ns": 6_000_000_000,
                "human_review_state": "unreviewed",
            },
        ],
    }
    worklist_path = tmp_path / "worklist.json"
    worklist_path.write_text(
        json.dumps(worklist, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    worklist_sha, _ = file_sha256(worklist_path)
    return labels_path, worklist_path, worklist_sha, candidate_a, candidate_b


def _write_spec(
    tmp_path,
    *,
    worklist_sha,
    decisions,
):
    spec = {
        "schema_version": HUMAN_CORRECTION_SPEC_SCHEMA_VERSION,
        "run_id": "run-1",
        "worklist_sha256": worklist_sha,
        "reviewer": {
            "kind": "human",
            "id": "operator",
        },
        "decisions": decisions,
    }
    path = tmp_path / "human-corrections.json"
    path.write_text(json.dumps(spec), encoding="utf-8")
    return path


def test_builds_hash_bound_human_correction_receipt(tmp_path):
    labels, worklist, worklist_sha, candidate_a, candidate_b = _fixture(
        tmp_path
    )
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "corrected",
                "note": "pelvis overlay too far right",
                "corrections": {
                    "derived": {
                        "pelvis_offset_m": 0.012,
                    },
                },
            },
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_b,
                "disposition": "accept_existing",
                "note": "looks correct",
            },
        ],
    )

    output = tmp_path / "human-correction-receipt.json"
    receipt = build_human_correction_receipt(
        spec,
        worklist,
        labels,
        output,
    )

    assert (
        receipt["schema_version"]
        == HUMAN_CORRECTION_RECEIPT_SCHEMA_VERSION
    )
    assert receipt["summary"]["decision_count"] == 2
    assert receipt["summary"]["corrected_count"] == 1
    assert receipt["summary"]["accept_existing_count"] == 1

    corrected = receipt["decisions"][0]
    assert corrected["before"] == {
        "derived": {"pelvis_offset_m": 0.04}
    }
    assert corrected["after"] == {
        "derived": {"pelvis_offset_m": 0.012}
    }
    assert corrected["target_human_review_state"] == "accepted"
    assert corrected["decision_id"].startswith("human-review/")


def test_rejects_tampered_worklist_binding(tmp_path):
    labels, worklist, worklist_sha, candidate_a, _ = _fixture(tmp_path)
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "accept_existing",
            }
        ],
    )
    raw = json.loads(worklist.read_text(encoding="utf-8"))
    raw["run_id"] = "tampered"
    worklist.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="worklist hash mismatch"):
        build_human_correction_receipt(
            spec,
            worklist,
            labels,
            tmp_path / "receipt.json",
        )


def test_rejects_teacher_labels_changed_after_worklist(tmp_path):
    labels, worklist, worklist_sha, candidate_a, _ = _fixture(tmp_path)
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "accept_existing",
            }
        ],
    )
    with labels.open("a", encoding="utf-8") as handle:
        handle.write("{}\n")

    with pytest.raises(ValueError, match="teacher-label hash"):
        build_human_correction_receipt(
            spec,
            worklist,
            labels,
            tmp_path / "receipt.json",
        )


def test_rejects_correction_that_changes_evidence_schema(tmp_path):
    labels, worklist, worklist_sha, candidate_a, _ = _fixture(tmp_path)
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "corrected",
                "corrections": {
                    "observed": {
                        "pelvis_offset_m": 0.012,
                    },
                },
            }
        ],
    )

    with pytest.raises(ValueError, match="introduces unknown fields"):
        build_human_correction_receipt(
            spec,
            worklist,
            labels,
            tmp_path / "receipt.json",
        )


def test_rejects_duplicate_candidate_decisions(tmp_path):
    labels, worklist, worklist_sha, candidate_a, _ = _fixture(tmp_path)
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "accept_existing",
            },
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "rejected",
            },
        ],
    )

    with pytest.raises(ValueError, match="reviewed more than once"):
        build_human_correction_receipt(
            spec,
            worklist,
            labels,
            tmp_path / "receipt.json",
        )


def test_rejects_patch_on_non_correction_disposition(tmp_path):
    labels, worklist, worklist_sha, candidate_a, _ = _fixture(tmp_path)
    spec = _write_spec(
        tmp_path,
        worklist_sha=worklist_sha,
        decisions=[
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_a,
                "disposition": "rejected",
                "corrections": {
                    "derived": {
                        "pelvis_offset_m": 0.0,
                    }
                },
            }
        ],
    )

    with pytest.raises(
        ValueError,
        match="cannot contain field corrections",
    ):
        build_human_correction_receipt(
            spec,
            worklist,
            labels,
            tmp_path / "receipt.json",
        )
