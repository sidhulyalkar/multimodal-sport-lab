from __future__ import annotations

import json

import pytest

from motionos.annotation_contract import (
    TEACHER_LABEL_SCHEMA_VERSION,
    build_annotation_manifest,
)
from motionos.personal_baseline import PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION
from motionos.personal_delta import (
    PERSONAL_SESSION_DELTA_SCHEMA_VERSION,
    PERSONAL_SESSION_DELTA_SPEC_SCHEMA_VERSION,
    build_personal_session_delta,
)
from motionos.reviewed_labels import REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _current_source(tmp_path, *, run_id, context, values):
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

    body = root / "body.jsonl"
    body.write_text('{"frame": 1}\n', encoding="utf-8")
    manifest_spec = {
        "run_id": run_id,
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
    manifest_spec_path = root / "annotation-spec.json"
    manifest_spec_path.write_text(
        json.dumps(manifest_spec),
        encoding="utf-8",
    )
    manifest = root / "annotation-manifest.json"
    build_annotation_manifest(manifest_spec_path, manifest)
    manifest_sha, manifest_bytes = file_sha256(manifest)
    video_sha, _ = file_sha256(video)

    rows = []
    for index, value in enumerate(values):
        reference = 2_000_000_000 + index * 1_000_000_000
        pts = alignment.map_reference_to_video_pts(reference)
        rows.append(
            {
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
                "inferred": {"movement_primitive": "neutral_balance"},
                "confidence": {},
                "model_versions": {"pose": "fixture"},
                "human_review_state": "accepted",
                "human_review_provenance": {
                    "correction_receipt_sha256": "c" * 64,
                    "decision_id": f"decision-{index}",
                    "disposition": (
                        "corrected" if index == 0 else "accept_existing"
                    ),
                    "corrected_fields": (
                        ["derived.pelvis_offset_m"]
                        if index == 0
                        else []
                    ),
                    "note": "",
                },
            }
        )

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


def _baseline(tmp_path, *, context, source_run_ids=("base-1", "base-2")):
    payload = {
        "schema_version": PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION,
        "profile_id": "local-athlete",
        "sport": "indo_board",
        "bindings": {
            "baseline_spec": {
                "path": "fixture",
                "sha256": "a" * 64,
                "byte_count": 1,
            },
            "sources": [
                {
                    "run_id": run_id,
                    "context": context,
                }
                for run_id in source_run_ids
            ],
        },
        "summary": {},
        "groups": [
            {
                "group_id": "personal-baseline/neutral-pelvis/abc",
                "metric_id": "neutral-pelvis",
                "evidence_class": "derived",
                "field": "pelvis_offset_m",
                "unit": "m",
                "selectors": {
                    "inferred.movement_primitive": "neutral_balance"
                },
                "context": context,
                "distribution": {
                    "sample_count": 20,
                    "median": 0.02,
                    "median_absolute_deviation": 0.01,
                    "q10": 0.005,
                    "q25": 0.01,
                    "q75": 0.03,
                    "q90": 0.04,
                    "minimum": 0.0,
                    "maximum": 0.05,
                },
                "review": {},
                "repeatability": {
                    "session_count": 2,
                    "status": "multi_session_descriptive",
                    "median_of_session_medians": 0.02,
                    "session_median_absolute_deviation": 0.005,
                    "sessions": [],
                },
            }
        ],
        "claim_boundary": "fixture",
    }
    path = tmp_path / "personal-baseline.json"
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def _spec(tmp_path, baseline, source):
    baseline_sha, _ = file_sha256(baseline)
    payload = {
        "schema_version": PERSONAL_SESSION_DELTA_SPEC_SCHEMA_VERSION,
        "baseline": str(baseline),
        "baseline_sha256": baseline_sha,
        "source": source,
    }
    path = tmp_path / "delta-spec.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_builds_descriptive_delta_against_exact_context(tmp_path):
    context = {
        "protocol": "indo_2min_v1",
        "stance": "regular",
    }
    baseline = _baseline(tmp_path, context=context)
    source = _current_source(
        tmp_path,
        run_id="current-1",
        context=context,
        values=[0.03, 0.05],
    )
    spec = _spec(tmp_path, baseline, source)

    delta = build_personal_session_delta(
        spec,
        tmp_path / "delta.json",
    )

    assert delta["schema_version"] == PERSONAL_SESSION_DELTA_SCHEMA_VERSION
    assert delta["summary"]["context_match"] is True
    assert delta["summary"]["comparison_count"] == 1

    comparison = delta["comparisons"][0]
    assert comparison["current"]["distribution"]["median"] == 0.04
    assert (
        comparison["delta"]["current_median_minus_baseline_median"]
        == pytest.approx(0.02)
    )
    assert (
        comparison["delta"]["in_baseline_pooled_mad_units"]
        == pytest.approx(2.0)
    )
    assert (
        comparison["delta"]["in_baseline_session_mad_units"]
        == pytest.approx(4.0)
    )
    assert (
        comparison["delta"]["baseline_interval_membership"]
        == "within_baseline_q10_q90"
    )
    assert comparison["current"]["human_corrected_sample_count"] == 1


def test_exact_context_mismatch_abstains_from_comparison(tmp_path):
    baseline = _baseline(
        tmp_path,
        context={"stance": "regular"},
    )
    source = _current_source(
        tmp_path,
        run_id="current-1",
        context={"stance": "switch"},
        values=[0.03, 0.05],
    )
    spec = _spec(tmp_path, baseline, source)

    delta = build_personal_session_delta(
        spec,
        tmp_path / "delta.json",
    )

    assert delta["summary"]["context_match"] is False
    assert delta["summary"]["comparison_count"] == 0
    assert delta["comparisons"] == []


def test_rejects_self_comparison_leakage(tmp_path):
    context = {"stance": "regular"}
    baseline = _baseline(
        tmp_path,
        context=context,
        source_run_ids=("current-1", "base-2"),
    )
    source = _current_source(
        tmp_path,
        run_id="current-1",
        context=context,
        values=[0.03, 0.05],
    )
    spec = _spec(tmp_path, baseline, source)

    with pytest.raises(ValueError, match="already included"):
        build_personal_session_delta(
            spec,
            tmp_path / "delta.json",
        )


def test_rejects_tampered_baseline(tmp_path):
    context = {"stance": "regular"}
    baseline = _baseline(tmp_path, context=context)
    source = _current_source(
        tmp_path,
        run_id="current-1",
        context=context,
        values=[0.03, 0.05],
    )
    spec = _spec(tmp_path, baseline, source)

    payload = json.loads(baseline.read_text(encoding="utf-8"))
    payload["profile_id"] = "tampered"
    baseline.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(ValueError, match="baseline hash mismatch"):
        build_personal_session_delta(
            spec,
            tmp_path / "delta.json",
        )
