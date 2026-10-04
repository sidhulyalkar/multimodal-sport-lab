from __future__ import annotations

import hashlib
import json

import pytest

from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    load_video_alignment,
    validate_video_alignment,
    write_video_alignment,
)


def _video(tmp_path):
    path = tmp_path / "action4.mp4"
    path.write_bytes(b"motionos-action4-fixture\n" * 128)
    return path


def _anchors(
    *,
    slope: float = 1.0 + 20e-6,
    intercept_ns: int = -8_000_000_000,
):
    reference_times = [
        12_000_000_000,
        50_000_000_000,
        110_000_000_000,
    ]
    return [
        VideoAlignmentAnchor(
            label=label,
            video_pts_ns=round((reference - intercept_ns) / slope),
            reference_time_ns=reference,
            uncertainty_ns=2_000_000,
            source="watch_sync_gesture_pose_peak",
        )
        for label, reference in zip(
            ("start", "middle", "end"),
            reference_times,
        )
    ]


def test_video_alignment_recovers_affine_map_and_trim(tmp_path):
    video = _video(tmp_path)
    receipt = build_video_alignment(
        video,
        run_id="indo-001",
        video_duration_ns=140_000_000_000,
        reference_start_ns=0,
        reference_end_ns=120_000_000_000,
        anchors=_anchors(),
        source_metadata={
            "camera": "DJI Osmo Action 4",
            "nominal_fps": 60,
        },
    )

    assert receipt.coverage.passed is True
    assert receipt.coverage.anchor_count == 3
    assert receipt.clock_model.drift_ppm == pytest.approx(20.0, abs=0.03)
    assert receipt.clock_model.residual_rms_ns < 2.0
    assert receipt.trim_video_start_ns == pytest.approx(
        8_000_000_000,
        abs=10_000,
    )
    assert receipt.trim_video_end_ns == pytest.approx(
        127_997_440_000,
        abs=20_000,
    )
    assert receipt.source_metadata["nominal_fps"] == 60

    digest = hashlib.sha256(video.read_bytes()).hexdigest()
    assert receipt.source_video_sha256 == digest
    assert receipt.source_video_byte_count == video.stat().st_size
    assert receipt.map_video_pts_to_reference(
        receipt.anchors[1].video_pts_ns
    ) == pytest.approx(50_000_000_000, abs=2)


def test_video_alignment_rejects_order_reversal(tmp_path):
    video = _video(tmp_path)
    anchors = _anchors()
    anchors[1] = VideoAlignmentAnchor(
        label="middle",
        video_pts_ns=anchors[0].video_pts_ns - 1,
        reference_time_ns=anchors[1].reference_time_ns,
    )

    with pytest.raises(ValueError, match="preserve temporal order"):
        build_video_alignment(
            video,
            run_id="indo-order",
            video_duration_ns=140_000_000_000,
            reference_start_ns=0,
            reference_end_ns=120_000_000_000,
            anchors=anchors,
        )


def test_video_alignment_marks_clustered_anchors_low_coverage(tmp_path):
    video = _video(tmp_path)
    anchors = [
        VideoAlignmentAnchor(
            label=f"a-{index}",
            video_pts_ns=(40 + index * 5) * 1_000_000_000,
            reference_time_ns=(40 + index * 5) * 1_000_000_000,
        )
        for index in range(3)
    ]

    receipt = build_video_alignment(
        video,
        run_id="indo-cluster",
        video_duration_ns=120_000_000_000,
        reference_start_ns=0,
        reference_end_ns=120_000_000_000,
        anchors=anchors,
    )

    assert receipt.coverage.passed is False
    assert receipt.coverage.has_middle_anchor is True
    assert receipt.coverage.reference_span_fraction == pytest.approx(
        10 / 120
    )


def test_video_alignment_round_trip_and_hash_validation(tmp_path):
    video = _video(tmp_path)
    spec = tmp_path / "alignment-spec.json"
    output = tmp_path / "video-alignment.json"
    spec.write_text(
        json.dumps(
            {
                "run_id": "indo-round-trip",
                "source_video": str(video),
                "video_duration_ns": 140_000_000_000,
                "reference_start_ns": 0,
                "reference_end_ns": 120_000_000_000,
                "source_metadata": {
                    "timecode": "phone-synchronized prior",
                },
                "anchors": [
                    {
                        "label": anchor.label,
                        "video_pts_ns": anchor.video_pts_ns,
                        "reference_time_ns": anchor.reference_time_ns,
                        "uncertainty_ns": anchor.uncertainty_ns,
                        "source": anchor.source,
                    }
                    for anchor in _anchors()
                ],
            }
        ),
        encoding="utf-8",
    )

    original = write_video_alignment(spec, output)
    loaded = load_video_alignment(output)

    assert loaded == original
    model = validate_video_alignment(loaded, video)
    assert model.slope == pytest.approx(original.clock_model.slope)

    video.write_bytes(video.read_bytes() + b"changed")
    with pytest.raises(ValueError, match="source hash mismatch"):
        validate_video_alignment(loaded, video)


def test_video_alignment_requires_three_unique_anchors(tmp_path):
    video = _video(tmp_path)
    with pytest.raises(ValueError, match="at least three"):
        build_video_alignment(
            video,
            run_id="indo-short",
            video_duration_ns=120_000_000_000,
            reference_start_ns=0,
            reference_end_ns=120_000_000_000,
            anchors=_anchors()[:2],
        )

    duplicate = _anchors()
    duplicate[1] = VideoAlignmentAnchor(
        label=duplicate[0].label,
        video_pts_ns=duplicate[1].video_pts_ns,
        reference_time_ns=duplicate[1].reference_time_ns,
    )
    with pytest.raises(ValueError, match="labels must be unique"):
        build_video_alignment(
            video,
            run_id="indo-duplicate",
            video_duration_ns=140_000_000_000,
            reference_start_ns=0,
            reference_end_ns=120_000_000_000,
            anchors=duplicate,
        )
