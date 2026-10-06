from __future__ import annotations

import json

import pytest

from motionos.annotation_contract import (
    TEACHER_LABEL_SCHEMA_VERSION,
    build_annotation_manifest,
)
from motionos.personal_baseline import (
    PERSONAL_BASELINE_SPEC_SCHEMA_VERSION,
    PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION,
    build_personal_movement_baseline,
)
from motionos.reviewed_labels import REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _source(
    tmp_path,
    *,
    run_id,
    values,
    context,
    corrected_index=None,
):
    root = tmp_path / run_id
    root.mkdir()

    video = root / "action4.mov"
    video.write_bytes((run_id + "\n").encode("utf-8") * 128)
    alignment = build_video_alignment(
        video,
        run_id=run_id,
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
    alignment_path = root / "video-alignment.json"
    alignment_path.write_text(
        json.dumps(alignment.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    derived = root / "body.jsonl"
    derived.write_text('{"frame": 1}\n', encoding="utf-8")
    annotation_spec = {
        "run_id": run_id,
        "sport": "indo_board",
        "source_video": str(video),
        "video_alignment": str(alignment_path),
        "renderer": {"id": "fixture", "version": "1"},
        "artifacts": [
            {"role": "body_frames", "path": str(derived)}
        ],
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
    annotation_spec_path = root / "annotation-spec.json"
    annotation_spec_path.write_text(
        json.dumps(annotation_spec),
        encoding="utf-8",
    )
    manifest = root / "annotation-manifest.json"
    build_annotation_manifest(annotation_spec_path, manifest)
    manifest_sha, manifest_bytes = file_sha256(manifest)
    video_sha, _ = file_sha256(video)

    rows = []
    for index, value in enumerate(values):
        reference_time = 2_000_000_000 + index * 1_000_000_000
        pts = alignment.map_reference_to_video_pts(reference_time)
        row = {
            "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
            "annotation_manifest_sha256": manifest_sha,
            "run_id": run_id,
            "sport": "indo_board",
            "source_video_sha256": video_sha,
            "source_frame_pts_ns": pts,
            "reference_time_ns":
                alignment.map_video_pts_to_reference(pts),
            "observed": {"body_pose_visible": True},
            "derived": {"pelvis_offset_m": value},
            "inferred": {
                "movement_primitive": (
                    "neutral_balance"
                    if index != len(values) - 1
                    else "edge_recovery"
                )
            },
            "confidence": {},
            "model_versions": {"pose": "fixture"},
            "human_review_state": (
                "rejected"
                if index == len(values) - 1
                else "accepted"
            ),
        }
        if corrected_index == index:
            row["human_review_provenance"] = {
                "correction_receipt_sha256": "c" * 64,
                "decision_id": f"decision-{index}",
                "disposition": "corrected",
                "corrected_fields": ["derived.pelvis_offset_m"],
                "note": "",
            }
        rows.append(row)

    labels = root / "reviewed-labels.jsonl"
    labels.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )
    labels_sha, labels_bytes = file_sha256(labels)

    receipt = root / "reviewed-labels-receipt.json"
    receipt.write_text(
        json.dumps(
            {
                "schema_version": REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION,
                "run_id": run_id,
                "bindings": {
                    "reviewed_labels": {
                        "path": str(labels),
                        "sha256": labels_sha,
                        "byte_count": labels_bytes,
                    },
                    "annotation_manifest": {
                        "path": str(manifest),
                        "sha256": manifest_sha,
                        "byte_count": manifest_bytes,
                    },
                },
                "summary": {},
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    return {
        "reviewed_labels": str(labels),
        "reviewed_labels_receipt": str(receipt),
        "annotation_manifest": str(manifest),
        "context": context,
    }


def _spec(tmp_path, sources):
    payload = {
        "schema_version": PERSONAL_BASELINE_SPEC_SCHEMA_VERSION,
        "profile_id": "local-athlete",
        "sport": "indo_board",
        "metrics": [
            {
                "id": "neutral-pelvis-offset",
                "evidence_class": "derived",
                "field": "pelvis_offset_m",
                "unit": "m",
                "selectors": {
                    "inferred.movement_primitive": "neutral_balance"
                },
            }
        ],
        "sources": sources,
    }
    path = tmp_path / "personal-baseline-spec.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_builds_multi_session_context_bound_baseline(tmp_path):
    context = {
        "protocol": "indo_2min_v1",
        "drill": "neutral_balance",
        "stance": "regular",
    }
    sources = [
        _source(
            tmp_path,
            run_id="run-1",
            values=[0.01, 0.02, 9.0],
            context=context,
            corrected_index=1,
        ),
        _source(
            tmp_path,
            run_id="run-2",
            values=[0.03, 0.04, 8.0],
            context=context,
        ),
    ]
    spec = _spec(tmp_path, sources)
    output = tmp_path / "baseline.json"

    baseline = build_personal_movement_baseline(spec, output)

    assert (
        baseline["schema_version"]
        == PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION
    )
    assert baseline["summary"]["source_session_count"] == 2
    assert baseline["summary"]["baseline_group_count"] == 1

    group = baseline["groups"][0]
    assert group["distribution"]["sample_count"] == 4
    assert group["distribution"]["median"] == pytest.approx(0.025)
    assert group["repeatability"]["session_count"] == 2
    assert (
        group["repeatability"]["status"]
        == "multi_session_descriptive"
    )
    assert (
        group["repeatability"]["median_of_session_medians"]
        == pytest.approx(0.025)
    )
    assert (
        group["repeatability"][
            "session_median_absolute_deviation"
        ]
        == pytest.approx(0.01)
    )
    assert group["review"]["human_corrected_sample_count"] == 1


def test_different_contexts_do_not_get_pooled(tmp_path):
    sources = [
        _source(
            tmp_path,
            run_id="run-1",
            values=[0.01, 0.02, 9.0],
            context={"stance": "regular"},
        ),
        _source(
            tmp_path,
            run_id="run-2",
            values=[0.03, 0.04, 8.0],
            context={"stance": "switch"},
        ),
    ]
    spec = _spec(tmp_path, sources)

    baseline = build_personal_movement_baseline(
        spec,
        tmp_path / "baseline.json",
    )

    assert baseline["summary"]["baseline_group_count"] == 2
    assert {
        group["context"]["stance"]
        for group in baseline["groups"]
    } == {"regular", "switch"}
    assert all(
        group["repeatability"]["status"] == "single_session_only"
        for group in baseline["groups"]
    )


def test_rejects_tampered_reviewed_labels(tmp_path):
    source = _source(
        tmp_path,
        run_id="run-1",
        values=[0.01, 0.02, 9.0],
        context={"stance": "regular"},
    )
    spec = _spec(tmp_path, [source])

    labels = tmp_path / "run-1" / "reviewed-labels.jsonl"
    with labels.open("a", encoding="utf-8") as handle:
        handle.write("{}\n")

    with pytest.raises(ValueError, match="reviewed-label hash mismatch"):
        build_personal_movement_baseline(
            spec,
            tmp_path / "baseline.json",
        )


def test_rejects_duplicate_run_sources(tmp_path):
    source = _source(
        tmp_path,
        run_id="run-1",
        values=[0.01, 0.02, 9.0],
        context={"stance": "regular"},
    )
    spec = _spec(tmp_path, [source, source])

    with pytest.raises(ValueError, match="unique run_id"):
        build_personal_movement_baseline(
            spec,
            tmp_path / "baseline.json",
        )
