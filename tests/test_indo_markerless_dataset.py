import json

import pytest

from motionos.indo_markerless_dataset import (
    build_markerless_dataset_index,
)


def _teacher_payload():
    return {
        "schema_version":
            "motionos.indo-fiducial-teacher-dataset.v1",
        "observations": [
            {
                "source_id": "camera-1",
                "frame_index": 3,
                "camera_pose_sequence": 0,
                "device_time_ns": 1_100_000_000,
                "time_s": 0.0,
                "review_status": "fiducial_teacher",
                "indo_board_equipment": {
                    "model_id": "vision-qr-indo-fiducials-v1",
                    "deck": {
                        "left_end": [0.2, 0.7],
                        "right_end": [0.8, 0.7],
                        "confidence": 0.9,
                        "provenance": "fiducial_measured",
                    },
                    "roller": {
                        "center": [0.5, 0.7],
                        "confidence": 0.88,
                        "provenance": "fiducial_measured",
                    },
                },
            },
            {
                "source_id": "camera-1",
                "frame_index": 6,
                "review_status": "model_proposed",
                "indo_board_equipment": {
                    "deck": {
                        "left_end": [0.2, 0.7],
                        "right_end": [0.8, 0.7],
                    },
                    "roller": {
                        "center": [0.5, 0.7],
                    },
                },
            },
        ],
    }


def _write_source(tmp_path, name="run-a"):
    video = tmp_path / f"{name}.mov"
    video.write_bytes(b"fake-video-evidence")

    labels = tmp_path / f"{name}-labels.json"
    labels.write_text(
        json.dumps(_teacher_payload()),
        encoding="utf-8",
    )
    return video, labels


def test_builds_hash_bound_markerless_dataset_index(tmp_path):
    video, labels = _write_source(tmp_path)
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.indo-markerless-dataset-spec.v1",
                "sources": [
                    {
                        "source_id": "run-a",
                        "video": video.name,
                        "teacher_labels": labels.name,
                        "subject_id": "subject-1",
                        "day_id": "day-1",
                        "run_id": "run-1",
                        "remount_id": "mount-1",
                        "camera_view": "front-oblique",
                        "board_id": "indo-1",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    output = tmp_path / "index.json"

    index = build_markerless_dataset_index(
        spec,
        output,
    )

    assert index["sample_count"] == 1
    assert index["source_count"] == 1
    assert index["sources"][0]["accepted_sample_count"] == 1
    assert index["sources"][0]["skipped_observation_count"] == 1

    sample = index["samples"][0]
    assert sample["frame_index"] == 3
    assert sample["subject_id"] == "subject-1"
    assert sample["day_id"] == "day-1"
    assert sample["run_id"] == "run-1"
    assert sample["camera_view"] == "front-oblique"
    assert sample["video_path"] == video.name
    assert output.is_file()


def test_duplicate_sample_identity_fails_closed(tmp_path):
    video, labels = _write_source(tmp_path)
    spec = tmp_path / "spec.json"
    source = {
        "source_id": "duplicate",
        "video": video.name,
        "teacher_labels": labels.name,
        "subject_id": "subject-1",
        "day_id": "day-1",
        "run_id": "run-1",
        "remount_id": "mount-1",
        "camera_view": "front",
        "board_id": "indo-1",
    }
    spec.write_text(
        json.dumps(
            {
                "sources": [
                    source,
                    source,
                ]
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="duplicate markerless sample_id",
    ):
        build_markerless_dataset_index(
            spec,
            tmp_path / "index.json",
        )


def test_incomplete_equipment_is_not_admitted(tmp_path):
    video = tmp_path / "run.mov"
    video.write_bytes(b"video")
    labels = tmp_path / "labels.json"
    labels.write_text(
        json.dumps(
            {
                "observations": [
                    {
                        "source_id": "camera-1",
                        "frame_index": 3,
                        "review_status": "fiducial_teacher",
                        "indo_board_equipment": {
                            "deck": {
                                "left_end": [0.2, 0.7],
                                "right_end": [0.8, 0.7],
                            },
                            "roller": None,
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "sources": [
                    {
                        "video": video.name,
                        "teacher_labels": labels.name,
                        "subject_id": "subject-1",
                        "day_id": "day-1",
                        "run_id": "run-1",
                        "remount_id": "mount-1",
                        "camera_view": "front",
                        "board_id": "indo-1",
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="no qualified samples",
    ):
        build_markerless_dataset_index(
            spec,
            tmp_path / "index.json",
        )
