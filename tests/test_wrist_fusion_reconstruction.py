import json
from types import SimpleNamespace

import pytest

import motionos.wrist_fusion_reconstruction as reconstruction
from motionos.clock import ClockModel
from motionos.provenance import sha256_file
from motionos.schema import SensorEvent
from motionos.wrist_fusion_reconstruction import (
    reconstruct_wrist_fusion_calibration,
    validate_wrist_fusion_reconstruction_spec,
)


def _pose_event(session_id, source_id):
    return SensorEvent(
        session_id=session_id,
        device_id=source_id,
        stream="/camera/pose2d",
        sequence=0,
        device_time_ns=1_000,
        payload={},
    )


def _fixture(tmp_path):
    vision = tmp_path / "vision.json"
    watch = tmp_path / "watch.jsonl"
    rig = tmp_path / "rig.json"
    iphone_journal = tmp_path / "iphone.jsonl"
    iphone_metadata = tmp_path / "iphone-metadata.json"
    action_journal = tmp_path / "action.jsonl"
    action_metadata = tmp_path / "action-metadata.json"
    spec = tmp_path / "reconstruction-spec.json"

    iphone_event = _pose_event("calibration-s1", "iphone-camera-id")
    action_event = _pose_event("calibration-s1", "dji-action4")
    iphone_journal.write_text(
        iphone_event.to_json() + "\n",
        encoding="utf-8",
    )
    action_journal.write_text(
        action_event.to_json() + "\n",
        encoding="utf-8",
    )

    landmarks = [
        {
            "landmark_id": f"sync-{index}",
            "session_id": "calibration-s1",
            "kind": "whole_body_impulse",
            "host_monotonic_time_ns":
                1_000_000_000 + index * 2_000_000_000,
            "created_at_unix_ms": 1000 + index,
            "note": None,
        }
        for index in range(3)
    ]
    watch_events = [
        SensorEvent(
            session_id="watch-s1",
            device_id="apple-watch",
            stream="/sync/vision_cue",
            sequence=index,
            device_time_ns=
                1_100_000_000 + index * 2_000_000_000,
            payload={
                "vision_session_id": "calibration-s1",
                "landmark_id": landmark["landmark_id"],
                "cue_kind": "whole_body_impulse",
            },
        )
        for index, landmark in enumerate(landmarks)
    ]
    watch.write_text(
        "\n".join(event.to_json() for event in watch_events) + "\n",
        encoding="utf-8",
    )

    action_video_hash = "a" * 64
    vision.write_text(
        json.dumps(
            {
                "schema_version": "motionos.vision-session.v1",
                "session_id": "calibration-s1",
                "sport": "indo_board",
                "capture_mode": "multiview_calibration",
                "created_at_utc": "2026-09-30T23:00:00Z",
                "camera_sources": [],
                "sync_landmarks": landmarks,
                "media_artifacts": [],
                "derived_artifacts": [
                    {
                        "artifact_id": "action4-pose2d-journal",
                        "source_id": "dji-action4",
                        "kind": "pose2d_journal",
                        "relative_path": "derived/action4.jsonl",
                        "sha256": sha256_file(action_journal),
                        "byte_count": action_journal.stat().st_size,
                        "generated_at_utc":
                            "2026-09-30T23:01:00Z",
                        "source_media_sha256": action_video_hash,
                    }
                ],
                "coaching_condition": "feedback_disabled",
                "claim_boundary": "",
            }
        ),
        encoding="utf-8",
    )

    rig.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-rig-receipt.v1",
                "rig_id": "rig-v1",
                "passed": True,
                "cameras": [
                    {"camera_id": "iphone-camera-id"},
                    {"camera_id": "dji-action4"},
                ],
            }
        ),
        encoding="utf-8",
    )

    iphone_metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera.v1",
                "session_id": "calibration-s1",
                "camera": {"unique_id": "iphone-camera-id"},
                "provenance": {
                    "camera_frames_jsonl_sha256":
                        sha256_file(iphone_journal)
                },
            }
        ),
        encoding="utf-8",
    )
    action_metadata.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.external-video-pose2d.v1",
                "session_id": "calibration-s1",
                "source_id": "dji-action4",
                "source_video": {
                    "sha256": action_video_hash,
                },
            }
        ),
        encoding="utf-8",
    )

    document = {
        "schema_version":
            "motionos.wrist-fusion-reconstruction-spec.v1",
        "vision_session": vision.name,
        "watch_journal": watch.name,
        "rig_receipt": rig.name,
        "iphone": {
            "journal": iphone_journal.name,
            "metadata": iphone_metadata.name,
        },
        "action4": {
            "journal": action_journal.name,
            "metadata": action_metadata.name,
        },
        "thresholds": {
            "maximum_pose_pair_ms": 10.0,
            "minimum_joint_confidence": 0.6,
        },
    }
    spec.write_text(
        json.dumps(document, indent=2),
        encoding="utf-8",
    )
    return spec, document, iphone_journal


def test_reconstruction_spec_validates_sealed_camera_journals(tmp_path):
    spec, document, _iphone = _fixture(tmp_path)

    assert validate_wrist_fusion_reconstruction_spec(spec) == document


def test_reconstruction_spec_rejects_modified_iphone_journal(tmp_path):
    spec, _document, iphone = _fixture(tmp_path)
    iphone.write_text(
        iphone.read_text(encoding="utf-8") + "{}\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="journal hash"):
        validate_wrist_fusion_reconstruction_spec(spec)


def test_calibration_reconstruction_writes_geometry_receipt(
    tmp_path,
    monkeypatch,
):
    spec, _document, _iphone = _fixture(tmp_path)
    output = tmp_path / "derived"

    def write_json(path, value):
        path.write_text(
            json.dumps(value),
            encoding="utf-8",
        )

    def fake_external(*args, **kwargs):
        write_json(
            args[3],
            {
                "schema_version":
                    "motionos.external-camera-sync.v1",
                "clock_model": {
                    "slope": 1.0,
                    "intercept_ns": 0.0,
                    "residual_rms_ns": 1_000_000.0,
                    "observations_used": 3,
                },
            },
        )
        return SimpleNamespace()

    def fake_bundle(*args):
        write_json(
            args[4],
            {
                "schema_version":
                    "motionos.vision-clock-bundle.v1",
            },
        )
        return {}

    clock = ClockModel(
        slope=1.0,
        intercept_ns=0.0,
        residual_rms_ns=1_000_000.0,
        observations_used=3,
    )
    monkeypatch.setattr(
        reconstruction,
        "write_external_camera_sync",
        fake_external,
    )
    monkeypatch.setattr(
        reconstruction,
        "build_vision_clock_bundle",
        fake_bundle,
    )
    monkeypatch.setattr(
        reconstruction,
        "load_clock_from_bundle",
        lambda *args: clock,
    )
    monkeypatch.setattr(
        reconstruction,
        "load_pose2d_journal",
        lambda path, source_id, clock_model: SimpleNamespace(
            source_id=source_id,
            observations=(object(), object()),
        ),
    )
    monkeypatch.setattr(
        reconstruction,
        "pair_pose_observations",
        lambda *args, **kwargs: ((object(), object()),),
    )

    def fake_correspondences(
        pairs,
        output_path,
        **kwargs,
    ):
        write_json(
            output_path,
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "pair_count": len(tuple(pairs)),
            },
        )

    def fake_geometry(_rig, _corr, output_path):
        write_json(
            output_path,
            {
                "schema_version":
                    "motionos.multiview-geometry-report.v1",
                "point_count": 10,
            },
        )
        return {}

    monkeypatch.setattr(
        reconstruction,
        "write_skeleton_sequence_correspondences",
        fake_correspondences,
    )
    monkeypatch.setattr(
        reconstruction,
        "triangulate_multiview",
        fake_geometry,
    )

    receipt = reconstruct_wrist_fusion_calibration(
        spec,
        output,
    )

    assert receipt["session_id"] == "calibration-s1"
    assert receipt["rig_id"] == "rig-v1"
    assert receipt["pose_pair_count"] == 1
    assert (
        output / "skeleton-correspondences.json"
    ).is_file()
    assert (output / "skeleton-geometry.json").is_file()
    assert (
        output / "wrist-fusion-reconstruction-receipt.json"
    ).is_file()
