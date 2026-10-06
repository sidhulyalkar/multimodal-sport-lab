from __future__ import annotations

import json

import pytest

from motionos.annotation_contract import (
    TEACHER_LABEL_SCHEMA_VERSION,
    build_annotation_manifest,
)
from motionos.human_corrections import (
    HUMAN_CORRECTION_SPEC_SCHEMA_VERSION,
    build_human_correction_receipt,
)
from motionos.replay_annotation import (
    REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
)
from motionos.reviewed_labels import (
    REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION,
    materialize_reviewed_labels,
)
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _fixture(tmp_path):
    video = tmp_path / "action4.mov"
    video.write_bytes(b"reviewed-label-fixture\n" * 128)
    alignment = build_video_alignment(
        video,
        run_id="run-reviewed",
        video_duration_ns=10_000_000_000,
        reference_start_ns=0,
        reference_end_ns=10_000_000_000,
        anchors=[
            VideoAlignmentAnchor(
                label="start",
                video_pts_ns=1_000_000_000,
                reference_time_ns=1_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="middle",
                video_pts_ns=5_000_000_000,
                reference_time_ns=5_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="end",
                video_pts_ns=9_000_000_000,
                reference_time_ns=9_000_000_000,
            ),
        ],
    )
    alignment_path = tmp_path / "video-alignment.json"
    alignment_path.write_text(
        json.dumps(alignment.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    body = tmp_path / "body.jsonl"
    body.write_text('{"frame": 1}\n', encoding="utf-8")
    spec = {
        "run_id": "run-reviewed",
        "sport": "indo_board",
        "source_video": str(video),
        "video_alignment": str(alignment_path),
        "renderer": {"id": "fixture", "version": "1"},
        "artifacts": [{"role": "body_frames", "path": str(body)}],
        "layers": [
            {
                "id": "body",
                "display_name": "Body",
                "semantic": "body_mesh",
                "evidence_class": "derived",
                "source_roles": ["body_frames"],
                "model_id": "pose",
                "model_version": "1",
            }
        ],
    }
    spec_path = tmp_path / "annotation-spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")
    manifest = tmp_path / "annotation-manifest.json"
    build_annotation_manifest(spec_path, manifest)
    manifest_sha, _ = file_sha256(manifest)
    video_sha, _ = file_sha256(video)

    labels = []
    for reference_time, pelvis in (
        (4_000_000_000, 0.04),
        (6_000_000_000, 0.02),
    ):
        pts = alignment.map_reference_to_video_pts(reference_time)
        labels.append(
            {
                "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
                "annotation_manifest_sha256": manifest_sha,
                "run_id": "run-reviewed",
                "sport": "indo_board",
                "source_video_sha256": video_sha,
                "source_frame_pts_ns": pts,
                "reference_time_ns":
                    alignment.map_video_pts_to_reference(pts),
                "observed": {"body_pose_visible": True},
                "derived": {"pelvis_offset_m": pelvis},
                "inferred": {"movement_primitive": "neutral_balance"},
                "confidence": {
                    "body_pose_visible": 0.95,
                    "pelvis_offset_m": 0.72,
                },
                "model_versions": {"pose": "fixture"},
                "human_review_state": "unreviewed",
            }
        )
    labels_path = tmp_path / "teacher-labels.jsonl"
    labels_path.write_text(
        "".join(json.dumps(row) + "\n" for row in labels),
        encoding="utf-8",
    )
    labels_sha, labels_bytes = file_sha256(labels_path)

    candidate_ids = [
        (
            f"teacher-frame/{row['source_frame_pts_ns']:020d}/"
            f"{row['reference_time_ns']:020d}"
        )
        for row in labels
    ]
    worklist_payload = {
        "schema_version": REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
        "run_id": "run-reviewed",
        "bindings": {
            "teacher_labels": {
                "path": str(labels_path),
                "sha256": labels_sha,
                "byte_count": labels_bytes,
            }
        },
        "work_items": [
            {
                "task_id": "replay-review/flag-1",
                "candidate_ids": candidate_ids,
            }
        ],
        "candidate_frames": [
            {
                "candidate_id": candidate_id,
                "label_index": index,
                "source_frame_pts_ns": row["source_frame_pts_ns"],
                "reference_time_ns": row["reference_time_ns"],
            }
            for index, (candidate_id, row)
            in enumerate(zip(candidate_ids, labels))
        ],
    }
    worklist = tmp_path / "worklist.json"
    worklist.write_text(
        json.dumps(worklist_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    worklist_sha, _ = file_sha256(worklist)

    correction_spec = {
        "schema_version": HUMAN_CORRECTION_SPEC_SCHEMA_VERSION,
        "run_id": "run-reviewed",
        "worklist_sha256": worklist_sha,
        "reviewer": {"kind": "human", "id": "operator"},
        "decisions": [
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_ids[0],
                "disposition": "corrected",
                "corrections": {
                    "derived": {"pelvis_offset_m": 0.012}
                },
            },
            {
                "task_id": "replay-review/flag-1",
                "candidate_id": candidate_ids[1],
                "disposition": "rejected",
            },
        ],
    }
    correction_spec_path = tmp_path / "corrections.json"
    correction_spec_path.write_text(
        json.dumps(correction_spec),
        encoding="utf-8",
    )
    correction_receipt = tmp_path / "correction-receipt.json"
    build_human_correction_receipt(
        correction_spec_path,
        worklist,
        labels_path,
        correction_receipt,
    )
    return labels_path, manifest, correction_receipt


def test_materializes_reviewed_labels_without_mutating_source(tmp_path):
    labels, manifest, correction_receipt = _fixture(tmp_path)
    source_before = labels.read_bytes()
    output = tmp_path / "reviewed-labels.jsonl"
    output_receipt = tmp_path / "reviewed-labels-receipt.json"

    result = materialize_reviewed_labels(
        correction_receipt,
        labels,
        manifest,
        output,
        output_receipt,
    )

    assert labels.read_bytes() == source_before
    reviewed = [
        json.loads(line)
        for line in output.read_text(encoding="utf-8").splitlines()
    ]
    assert reviewed[0]["derived"]["pelvis_offset_m"] == 0.012
    assert reviewed[0]["human_review_state"] == "accepted"
    assert "pelvis_offset_m" not in reviewed[0]["confidence"]
    assert reviewed[1]["human_review_state"] == "rejected"

    provenance = reviewed[0]["human_review_provenance"]
    assert provenance["disposition"] == "corrected"
    assert provenance["corrected_fields"] == [
        "derived.pelvis_offset_m"
    ]

    assert (
        result["schema_version"]
        == REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
    )
    assert result["summary"]["corrected_field_count"] == 1
    assert result["summary"]["rejected_count"] == 1
    assert (
        result["summary"]["validated_reviewed_label_count"]
        == 2
    )


def test_rejects_source_labels_changed_after_correction(tmp_path):
    labels, manifest, correction_receipt = _fixture(tmp_path)
    with labels.open("a", encoding="utf-8") as handle:
        handle.write("{}\n")

    with pytest.raises(ValueError, match="teacher-label hash"):
        materialize_reviewed_labels(
            correction_receipt,
            labels,
            manifest,
            tmp_path / "reviewed.jsonl",
            tmp_path / "receipt.json",
        )
