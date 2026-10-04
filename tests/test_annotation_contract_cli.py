from __future__ import annotations

import json

from motionos.annotation_contract import TEACHER_LABEL_SCHEMA_VERSION
from motionos.cli import main
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _fixture(tmp_path):
    video = tmp_path / "camera.mov"
    video.write_bytes(b"annotation-cli-video" * 64)

    alignment = build_video_alignment(
        video,
        run_id="annotation-cli",
        video_duration_ns=130_000_000_000,
        reference_start_ns=0,
        reference_end_ns=120_000_000_000,
        anchors=[
            VideoAlignmentAnchor(
                label=label,
                video_pts_ns=video_pts,
                reference_time_ns=reference,
                uncertainty_ns=1_000_000,
            )
            for label, video_pts, reference in (
                ("start", 15_000_000_000, 10_000_000_000),
                ("middle", 65_000_000_000, 60_000_000_000),
                ("end", 115_000_000_000, 110_000_000_000),
            )
        ],
    )
    alignment_path = tmp_path / "alignment.json"
    alignment_path.write_text(
        json.dumps(alignment.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    spec = {
        "run_id": "annotation-cli",
        "sport": "indo_board",
        "source_video": str(video),
        "video_alignment": str(alignment_path),
        "renderer": {
            "id": "motionos-replay",
            "version": "0.1",
        },
        "layers": [
            {
                "id": "video",
                "display_name": "Video",
                "semantic": "video",
                "evidence_class": "observed",
                "source_roles": ["source_video"],
            },
            {
                "id": "balance",
                "display_name": "Balance",
                "semantic": "balance",
                "evidence_class": "derived",
                "source_roles": ["video_alignment"],
            },
        ],
    }
    spec_path = tmp_path / "annotation-spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")
    return video, alignment, spec_path


def test_annotation_contract_cli_round_trip(tmp_path, capsys):
    video, alignment, spec_path = _fixture(tmp_path)
    manifest_path = tmp_path / "annotation-manifest.json"

    assert main(
        [
            "build-annotation-manifest",
            str(spec_path),
            str(manifest_path),
        ]
    ) == 0
    built = json.loads(capsys.readouterr().out)
    assert built["run_id"] == "annotation-cli"

    assert main(
        [
            "validate-annotation-manifest",
            str(manifest_path),
        ]
    ) == 0
    validated = json.loads(capsys.readouterr().out)
    assert validated["source_video"]["filename"] == "camera.mov"

    manifest_sha, _ = file_sha256(manifest_path)
    video_sha, _ = file_sha256(video)
    reference_time = 60_000_000_000
    pts = alignment.map_reference_to_video_pts(reference_time)
    labels = tmp_path / "teacher-labels.jsonl"
    labels.write_text(
        json.dumps(
            {
                "schema_version": TEACHER_LABEL_SCHEMA_VERSION,
                "annotation_manifest_sha256": manifest_sha,
                "run_id": "annotation-cli",
                "sport": "indo_board",
                "source_video_sha256": video_sha,
                "source_frame_pts_ns": pts,
                "reference_time_ns":
                    alignment.map_video_pts_to_reference(pts),
                "observed": {"rider_visible": True},
                "derived": {"balance_proxy": 0.8},
                "inferred": {},
                "confidence": {"balance_proxy": 0.7},
                "model_versions": {},
                "human_review_state": "unreviewed",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    assert main(
        [
            "validate-teacher-labels",
            str(labels),
            str(manifest_path),
        ]
    ) == 0
    label_result = json.loads(capsys.readouterr().out)
    assert label_result["passed"] is True
    assert label_result["label_count"] == 1
