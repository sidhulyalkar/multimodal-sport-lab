from __future__ import annotations

import json

import pytest

from motionos.annotation_contract import (
    ANNOTATION_MANIFEST_SCHEMA_VERSION,
    TEACHER_LABEL_SCHEMA_VERSION,
    build_annotation_manifest,
    validate_annotation_manifest,
    validate_teacher_labels,
)
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _video(tmp_path):
    path = tmp_path / "action4.mov"
    path.write_bytes(b"action4-fixture\n" * 256)
    return path


def _alignment(tmp_path, video):
    slope = 1.0 + 15e-6
    intercept_ns = -7_000_000_000
    refs = [
        12_000_000_000,
        55_000_000_000,
        110_000_000_000,
    ]
    receipt = build_video_alignment(
        video,
        run_id="indo-annotation",
        video_duration_ns=140_000_000_000,
        reference_start_ns=0,
        reference_end_ns=120_000_000_000,
        anchors=[
            VideoAlignmentAnchor(
                label=label,
                video_pts_ns=round(
                    (reference - intercept_ns) / slope
                ),
                reference_time_ns=reference,
                uncertainty_ns=2_000_000,
                source="watch_sync_gesture_pose_peak",
            )
            for label, reference in zip(
                ("start", "middle", "end"),
                refs,
            )
        ],
    )
    path = tmp_path / "video-alignment.json"
    path.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt, path


def _annotation_spec(tmp_path, video, alignment_path):
    body = tmp_path / "body-frames.jsonl"
    body.write_text('{"frame":1}\n', encoding="utf-8")
    coach = tmp_path / "coach.json"
    coach.write_text('{"tip":"smaller earlier correction"}\n', encoding="utf-8")
    muscles = tmp_path / "muscle-model.json"
    muscles.write_text('{"model":"fixture"}\n', encoding="utf-8")

    spec = {
        "run_id": "indo-annotation",
        "sport": "indo_board",
        "source_video": str(video),
        "video_alignment": str(alignment_path),
        "renderer": {
            "id": "motionos-annotation-renderer",
            "version": "0.1.0",
        },
        "timing_tolerance_ns": 5_000_000,
        "artifacts": [
            {"role": "body_frames", "path": str(body)},
            {"role": "coaching_report", "path": str(coach)},
            {"role": "muscle_model", "path": str(muscles)},
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
                "model_id": "body-fit",
                "model_version": "1.0",
            },
            {
                "id": "mechanics",
                "display_name": "Mechanics",
                "semantic": "joint_mechanics",
                "evidence_class": "derived",
                "source_roles": ["body_frames", "video_alignment"],
            },
            {
                "id": "muscles",
                "display_name": "Muscle estimate",
                "semantic": "estimated_muscle_demand",
                "evidence_class": "inferred",
                "source_roles": ["body_frames", "muscle_model"],
                "model_id": "fixture-musculoskeletal",
                "model_version": "0.1",
                "claim_boundary": "Estimated demand, not measured activation.",
            },
            {
                "id": "coach",
                "display_name": "Coaching",
                "semantic": "coaching",
                "evidence_class": "inferred",
                "source_roles": ["coaching_report"],
            },
        ],
    }
    path = tmp_path / "annotation-spec.json"
    path.write_text(json.dumps(spec), encoding="utf-8")
    return spec, path


def test_annotation_manifest_binds_sources_layers_and_alignment(tmp_path):
    video = _video(tmp_path)
    _, alignment_path = _alignment(tmp_path, video)
    _, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    output = tmp_path / "annotation-manifest.json"

    manifest = build_annotation_manifest(spec_path, output)

    assert manifest["schema_version"] == ANNOTATION_MANIFEST_SCHEMA_VERSION
    assert manifest["video_alignment"]["coverage_passed"] is True
    assert manifest["source_video"]["sha256"] == file_sha256(video)[0]
    assert [layer["id"] for layer in manifest["layers"]] == [
        "video",
        "body",
        "mechanics",
        "muscles",
        "coach",
    ]
    assert manifest["layers"][3]["semantic"] == "estimated_muscle_demand"
    assert validate_annotation_manifest(output) == manifest


def test_annotation_manifest_rejects_tampered_derived_artifact(tmp_path):
    video = _video(tmp_path)
    _, alignment_path = _alignment(tmp_path, video)
    _, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    output = tmp_path / "annotation-manifest.json"
    manifest = build_annotation_manifest(spec_path, output)

    body = next(
        item for item in manifest["artifacts"]
        if item["role"] == "body_frames"
    )
    with open(body["path"], "a", encoding="utf-8") as handle:
        handle.write('{"frame":2}\n')

    with pytest.raises(ValueError, match="artifact hash mismatch"):
        validate_annotation_manifest(output)


def test_muscle_demand_cannot_masquerade_as_measurement(tmp_path):
    video = _video(tmp_path)
    _, alignment_path = _alignment(tmp_path, video)
    spec, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    spec["layers"][3]["evidence_class"] = "observed"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")

    with pytest.raises(ValueError, match="must be classified as inferred"):
        build_annotation_manifest(
            spec_path,
            tmp_path / "annotation-manifest.json",
        )


def test_measured_muscle_activation_requires_emg_source(tmp_path):
    video = _video(tmp_path)
    _, alignment_path = _alignment(tmp_path, video)
    spec, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    spec["layers"][3] = {
        "id": "muscles",
        "display_name": "Muscle activation",
        "semantic": "measured_muscle_activation",
        "evidence_class": "observed",
        "source_roles": ["muscle_model"],
    }
    spec_path.write_text(json.dumps(spec), encoding="utf-8")

    with pytest.raises(ValueError, match="requires an EMG source role"):
        build_annotation_manifest(
            spec_path,
            tmp_path / "annotation-manifest.json",
        )


def test_teacher_labels_bind_manifest_video_and_time_map(tmp_path):
    video = _video(tmp_path)
    alignment, alignment_path = _alignment(tmp_path, video)
    _, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    manifest_path = tmp_path / "annotation-manifest.json"
    build_annotation_manifest(spec_path, manifest_path)
    manifest_sha, _ = file_sha256(manifest_path)
    video_sha, _ = file_sha256(video)

    labels_path = tmp_path / "teacher-labels.jsonl"
    rows = []
    for index, reference_time in enumerate(
        (20_000_000_000, 60_000_000_000, 100_000_000_000)
    ):
        pts = alignment.map_reference_to_video_pts(reference_time)
        rows.append(
            {
                "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
                "annotation_manifest_sha256": manifest_sha,
                "run_id": "indo-annotation",
                "sport": "indo_board",
                "source_video_sha256": video_sha,
                "source_frame_pts_ns": pts,
                "reference_time_ns": alignment.map_video_pts_to_reference(pts),
                "observed": {
                    "body_pose_visible": True,
                    "board_visible": True,
                },
                "derived": {
                    "roller_along_deck": 0.1 * index,
                    "pelvis_offset_m": 0.02 * index,
                },
                "inferred": {
                    "movement_primitive": "neutral_balance",
                    "estimated_muscle_demand": {
                        "left_thigh": 0.42 + index * 0.02,
                    },
                },
                "confidence": {
                    "body_pose_visible": 0.95,
                    "roller_along_deck": 0.88,
                    "estimated_muscle_demand": 0.55,
                },
                "model_versions": {
                    "pose": "vision3d-current",
                    "muscle": "fixture-musculoskeletal@0.1",
                },
                "human_review_state": "unreviewed",
            }
        )
    labels_path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )

    result = validate_teacher_labels(labels_path, manifest_path)

    assert result.passed is True
    assert result.label_count == 3
    assert result.max_mapping_error_ns == 0
    assert "roller_along_deck" in result.derived_fields
    assert "estimated_muscle_demand" in result.inferred_fields


def test_teacher_labels_reject_manifest_or_timing_mismatch(tmp_path):
    video = _video(tmp_path)
    alignment, alignment_path = _alignment(tmp_path, video)
    _, spec_path = _annotation_spec(tmp_path, video, alignment_path)
    manifest_path = tmp_path / "annotation-manifest.json"
    build_annotation_manifest(spec_path, manifest_path)
    video_sha, _ = file_sha256(video)

    pts = alignment.map_reference_to_video_pts(60_000_000_000)
    row = {
        "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
        "annotation_manifest_sha256": "0" * 64,
        "run_id": "indo-annotation",
        "sport": "indo_board",
        "source_video_sha256": video_sha,
        "source_frame_pts_ns": pts,
        "reference_time_ns": 60_000_000_000,
        "observed": {},
        "derived": {},
        "inferred": {},
        "confidence": {},
        "model_versions": {},
        "human_review_state": "unreviewed",
    }
    labels_path = tmp_path / "bad-labels.jsonl"
    labels_path.write_text(json.dumps(row) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="manifest hash mismatch"):
        validate_teacher_labels(labels_path, manifest_path)

    manifest_sha, _ = file_sha256(manifest_path)
    row["annotation_manifest_sha256"] = manifest_sha
    row["reference_time_ns"] = 80_000_000_000
    labels_path.write_text(json.dumps(row) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="mapping error"):
        validate_teacher_labels(labels_path, manifest_path)
