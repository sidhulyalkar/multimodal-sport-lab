from __future__ import annotations

import json

import pytest

from motionos.annotation_contract import (
    TEACHER_LABEL_SCHEMA_VERSION,
    build_annotation_manifest,
)
from motionos.replay_annotation import (
    REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION,
    build_replay_annotation_worklist,
)
from motionos.replay_review import (
    REPLAY_REVIEW_FLAG_SCHEMA_VERSION,
    REPLAY_REVIEW_LEDGER_SCHEMA_VERSION,
    build_replay_review_queue,
)
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _fixture(tmp_path):
    video = tmp_path / "action4.mp4"
    video.write_bytes(b"action4-review-fixture\n" * 128)

    alignment = build_video_alignment(
        video,
        run_id="run-review",
        video_duration_ns=12_000_000_000,
        reference_start_ns=0,
        reference_end_ns=12_000_000_000,
        anchors=[
            VideoAlignmentAnchor(
                label="start",
                video_pts_ns=1_000_000_000,
                reference_time_ns=1_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="middle",
                video_pts_ns=6_000_000_000,
                reference_time_ns=6_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="end",
                video_pts_ns=11_000_000_000,
                reference_time_ns=11_000_000_000,
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
        "run_id": "run-review",
        "sport": "indo_board",
        "source_video": str(video),
        "video_alignment": str(alignment_path),
        "renderer": {"id": "review-fixture", "version": "1"},
        "artifacts": [
            {"role": "body_frames", "path": str(body)},
        ],
        "layers": [
            {
                "id": "video",
                "display_name": "Video",
                "semantic": "video",
                "evidence_class": "observed",
                "source_roles": ["source_video"],
            },
            {
                "id": "body",
                "display_name": "Body",
                "semantic": "body_mesh",
                "evidence_class": "derived",
                "source_roles": ["body_frames"],
                "model_id": "pose",
                "model_version": "1",
            },
        ],
    }
    spec_path = tmp_path / "annotation-spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")
    manifest_path = tmp_path / "annotation-manifest.json"
    build_annotation_manifest(spec_path, manifest_path)

    manifest_sha, _ = file_sha256(manifest_path)
    video_sha, _ = file_sha256(video)
    labels = []
    for reference_time_ns in (
        4_000_000_000,
        5_000_000_000,
        6_000_000_000,
        9_000_000_000,
    ):
        pts = alignment.map_reference_to_video_pts(reference_time_ns)
        labels.append(
            {
                "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
                "annotation_manifest_sha256": manifest_sha,
                "run_id": "run-review",
                "sport": "indo_board",
                "source_video_sha256": video_sha,
                "source_frame_pts_ns": pts,
                "reference_time_ns": alignment.map_video_pts_to_reference(
                    pts
                ),
                "observed": {"body_pose_visible": True},
                "derived": {"pelvis_offset_m": 0.01},
                "inferred": {"movement_primitive": "neutral_balance"},
                "confidence": {"body_pose_visible": 0.95},
                "model_versions": {"pose": "fixture"},
                "human_review_state": "unreviewed",
            }
        )
    labels_path = tmp_path / "teacher-labels.jsonl"
    labels_path.write_text(
        "".join(json.dumps(row) + "\n" for row in labels),
        encoding="utf-8",
    )

    alignment_sha, _ = file_sha256(alignment_path)
    ledger = {
        "schema_version": REPLAY_REVIEW_LEDGER_SCHEMA_VERSION,
        "run_id": "run-review",
        "flags": [
            {
                "schema_version": REPLAY_REVIEW_FLAG_SCHEMA_VERSION,
                "id": "flag-1",
                "run_id": "run-review",
                "recorded_at_utc": "2026-10-05T00:00:00Z",
                "reference_time_ns": 5_000_000_000,
                "action4_video_pts_ns":
                    alignment.map_reference_to_video_pts(
                        5_000_000_000
                    ),
                "scope": "action4_pose",
                "verdict": "wrong",
                "note": "hip overlay jumped",
                "window_before_ns": 1_500_000_000,
                "window_after_ns": 1_500_000_000,
                "iphone_pose_available": True,
                "action4_pose_available": True,
                "equipment_available": True,
                "observed_playback_drift_ms": 4.0,
                "artifact_bindings": [
                    {
                        "role": "video_alignment",
                        "sha256": alignment_sha,
                        "filename": alignment_path.name,
                    },
                    {
                        "role": "action4_video",
                        "sha256": video_sha,
                        "filename": video.name,
                    },
                ],
            },
            {
                "schema_version": REPLAY_REVIEW_FLAG_SCHEMA_VERSION,
                "id": "flag-2",
                "run_id": "run-review",
                "recorded_at_utc": "2026-10-05T00:00:01Z",
                "reference_time_ns": 8_000_000_000,
                "action4_video_pts_ns":
                    alignment.map_reference_to_video_pts(
                        8_000_000_000
                    ),
                "scope": "equipment",
                "verdict": "inspect",
                "note": "",
                "window_before_ns": 250_000_000,
                "window_after_ns": 250_000_000,
                "iphone_pose_available": True,
                "action4_pose_available": True,
                "equipment_available": False,
                "observed_playback_drift_ms": 2.0,
                "artifact_bindings": [
                    {
                        "role": "video_alignment",
                        "sha256": alignment_sha,
                        "filename": alignment_path.name,
                    },
                    {
                        "role": "action4_video",
                        "sha256": video_sha,
                        "filename": video.name,
                    },
                ],
            },
        ],
    }
    ledger_path = tmp_path / "replay-review-ledger.json"
    ledger_path.write_text(json.dumps(ledger), encoding="utf-8")
    queue_path = tmp_path / "replay-review-queue.json"
    build_replay_review_queue(
        ledger_path,
        alignment_path,
        queue_path,
    )
    return queue_path, manifest_path, labels_path


def test_builds_evidence_bound_annotation_worklist(tmp_path):
    queue, manifest, labels = _fixture(tmp_path)
    output = tmp_path / "replay-annotation-worklist.json"

    payload = build_replay_annotation_worklist(
        queue,
        manifest,
        labels,
        output,
    )

    assert (
        payload["schema_version"]
        == REPLAY_ANNOTATION_WORKLIST_SCHEMA_VERSION
    )
    assert payload["run_id"] == "run-review"
    assert payload["summary"]["review_task_count"] == 2
    assert payload["summary"]["candidate_frame_count"] == 3
    assert payload["summary"]["video_only_task_count"] == 1
    first = payload["work_items"][0]
    assert first["candidate_count"] == 3
    assert first["coverage_status"] == "teacher_labels_available"
    second = payload["work_items"][1]
    assert second["candidate_count"] == 0
    assert second["coverage_status"] == "video_review_only"
    assert all(
        item["human_review_state"] == "unreviewed"
        for item in payload["candidate_frames"]
    )


def test_rejects_queue_from_different_alignment(tmp_path):
    queue, manifest, labels = _fixture(tmp_path)
    raw = json.loads(queue.read_text(encoding="utf-8"))
    raw["alignment"]["sha256"] = "0" * 64
    queue.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="alignment hash mismatch"):
        build_replay_annotation_worklist(
            queue,
            manifest,
            labels,
            tmp_path / "worklist.json",
        )


def test_rejects_tampered_teacher_labels(tmp_path):
    queue, manifest, labels = _fixture(tmp_path)
    with labels.open("a", encoding="utf-8") as handle:
        handle.write('{"tampered": true}\n')

    with pytest.raises((ValueError, TypeError)):
        build_replay_annotation_worklist(
            queue,
            manifest,
            labels,
            tmp_path / "worklist.json",
        )
