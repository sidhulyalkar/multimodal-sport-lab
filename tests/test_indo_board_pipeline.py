import json

import pytest

import motionos.indo_board_pipeline as pipeline_module
from motionos.indo_board_pipeline import (
    process_indo_board_pipeline,
    validate_indo_board_pipeline_spec,
)
from motionos.provenance import sha256_file
from motionos.schema import SensorEvent


def _write_pose_journal(path, *, source_id):
    event = SensorEvent(
        session_id="vision-s1",
        device_id=source_id,
        stream="/camera/pose2d",
        sequence=0,
        device_time_ns=1_000,
        payload={},
    )
    path.write_text(event.to_json() + "\n", encoding="utf-8")


def _fixture(tmp_path):
    vision = tmp_path / "vision.json"
    watch = tmp_path / "watch.jsonl"
    rig = tmp_path / "rig.json"
    layout = tmp_path / "layout.json"
    iphone_video = tmp_path / "iphone.mov"
    iphone_journal = tmp_path / "iphone.jsonl"
    iphone_metadata = tmp_path / "iphone-metadata.json"
    action_video = tmp_path / "action.mov"
    action_journal = tmp_path / "action.jsonl"
    action_metadata = tmp_path / "action-metadata.json"
    profile = tmp_path / "profile.json"
    spec = tmp_path / "pipeline.json"

    landmarks = [
        {
            "landmark_id": f"sync-{index}",
            "session_id": "vision-s1",
            "kind": "whole_body_impulse",
            "host_monotonic_time_ns":
                1_000_000_000 + index * 2_000_000_000,
            "created_at_unix_ms": 1_000 + index,
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
                "vision_session_id": "vision-s1",
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
    rig.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-rig-receipt.v1",
                "rig_id": "indo-board-two-camera-v1",
                "passed": True,
                "cameras": [
                    {"camera_id": "iphone-camera-id"},
                    {"camera_id": "dji-action4"},
                ],
            }
        ),
        encoding="utf-8",
    )
    layout.write_text("{}\n", encoding="utf-8")
    iphone_video.write_bytes(b"iphone-video")
    action_video.write_bytes(b"action-video")
    _write_pose_journal(
        iphone_journal,
        source_id="iphone-camera-id",
    )
    _write_pose_journal(
        action_journal,
        source_id="dji-action4",
    )

    iphone_video_hash = sha256_file(iphone_video)
    iphone_journal_hash = sha256_file(iphone_journal)
    iphone_metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera.v1",
                "session_id": "vision-s1",
                "camera": {"unique_id": "iphone-camera-id"},
                "provenance": {
                    "camera_mov_sha256": iphone_video_hash,
                    "camera_frames_jsonl_sha256":
                        iphone_journal_hash,
                },
            }
        ),
        encoding="utf-8",
    )

    action_video_hash = sha256_file(action_video)
    action_journal_hash = sha256_file(action_journal)
    action_metadata.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.external-video-pose2d.v1",
                "session_id": "vision-s1",
                "source_id": "dji-action4",
                "source_video": {
                    "filename": action_video.name,
                    "sha256": action_video_hash,
                    "byte_count": action_video.stat().st_size,
                },
            }
        ),
        encoding="utf-8",
    )
    action_metadata_hash = sha256_file(action_metadata)

    vision.write_text(
        json.dumps(
            {
                "schema_version": "motionos.vision-session.v1",
                "session_id": "vision-s1",
                "sport": "indo_board",
                "capture_mode": "multiview_calibration",
                "created_at_utc": "2026-09-30T23:00:00Z",
                "camera_sources": [],
                "sync_landmarks": landmarks,
                "media_artifacts": [
                    {
                        "source_id": "dji-action4",
                        "relative_path": "external/action4.mov",
                        "original_filename": action_video.name,
                        "sha256": action_video_hash,
                        "byte_count": action_video.stat().st_size,
                        "imported_at_utc":
                            "2026-09-30T23:00:00Z",
                    }
                ],
                "derived_artifacts": [
                    {
                        "artifact_id":
                            "action4-pose2d-journal",
                        "source_id": "dji-action4",
                        "kind": "pose2d_journal",
                        "relative_path":
                            "derived/action4-frames.jsonl",
                        "sha256": action_journal_hash,
                        "byte_count":
                            action_journal.stat().st_size,
                        "generated_at_utc":
                            "2026-09-30T23:01:00Z",
                        "source_media_sha256":
                            action_video_hash,
                    },
                    {
                        "artifact_id":
                            "action4-pose2d-metadata",
                        "source_id": "dji-action4",
                        "kind": "pose2d_metadata",
                        "relative_path":
                            "derived/action4-metadata.json",
                        "sha256": action_metadata_hash,
                        "byte_count":
                            action_metadata.stat().st_size,
                        "generated_at_utc":
                            "2026-09-30T23:01:00Z",
                        "source_media_sha256":
                            action_video_hash,
                    },
                ],
                "coaching_condition": "feedback_disabled",
                "claim_boundary": "",
            }
        ),
        encoding="utf-8",
    )

    document = {
        "schema_version": "motionos.indo-board-pipeline-spec.v1",
        "vision_session": vision.name,
        "watch_journal": watch.name,
        "rig_receipt": rig.name,
        "board_marker_layout": layout.name,
        "longitudinal_profile": profile.name,
        "iphone": {
            "video": iphone_video.name,
            "journal": iphone_journal.name,
            "metadata": iphone_metadata.name,
        },
        "action4": {
            "video": action_video.name,
            "journal": action_journal.name,
            "metadata": action_metadata.name,
        },
        "thresholds": {
            "maximum_pose_pair_ms": 10,
            "maximum_marker_pair_ms": 10,
            "minimum_joint_confidence": 0.6,
            "marker_frame_stride": 1,
            "maximum_board_scale_error_fraction": 0.03,
            "maximum_skeleton_board_pair_ms": 20,
            "minimum_modeled_mass_coverage": 0.75,
            "maximum_board_fit_residual_m": 0.03,
            "minimum_pose_confidence": 0.6,
            "maximum_timing_uncertainty_ms": 20,
            "maximum_reprojection_rms_px": 3,
            "minimum_longitudinal_confidence": 0.6,
        },
        "wrist_fusion": {
            "watch_acceleration_std_m_s2": 0.2,
            "vision_acceleration_std_m_s2": 0.4,
            "maximum_acceleration_rate_m_s3": 25.0,
            "maximum_time_delta_ms": 20,
        },
    }
    spec.write_text(
        json.dumps(document, indent=2),
        encoding="utf-8",
    )
    return spec, document, rig


def test_pipeline_preflight_accepts_matching_camera_contract(tmp_path):
    spec, document, _rig = _fixture(tmp_path)

    validated = validate_indo_board_pipeline_spec(spec)

    assert validated == document


def test_pipeline_preflight_rejects_camera_id_not_in_rig(tmp_path):
    spec, _document, rig = _fixture(tmp_path)
    raw_rig = json.loads(rig.read_text(encoding="utf-8"))
    raw_rig["cameras"][0]["camera_id"] = "different-iphone"
    rig.write_text(json.dumps(raw_rig), encoding="utf-8")

    with pytest.raises(
        ValueError,
        match="does not contain journal camera IDs",
    ):
        validate_indo_board_pipeline_spec(spec)


@pytest.mark.parametrize(
    ("section", "key", "value", "message"),
    [
        (
            "thresholds",
            "minimum_joint_confidence",
            1.2,
            "between 0 and 1",
        ),
        (
            "thresholds",
            "marker_frame_stride",
            1.5,
            "positive integer",
        ),
        (
            "wrist_fusion",
            "watch_acceleration_std_m_s2",
            "REPLACE_ME",
            "must be numeric",
        ),
        (
            "wrist_fusion",
            "maximum_acceleration_rate_m_s3",
            0,
            "must be positive",
        ),
    ],
)
def test_pipeline_preflight_rejects_invalid_numeric_contract(
    tmp_path,
    section,
    key,
    value,
    message,
):
    spec, document, _rig = _fixture(tmp_path)
    document[section][key] = value
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        validate_indo_board_pipeline_spec(spec)


def test_pipeline_preflight_requires_three_sync_landmarks(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    vision = tmp_path / document["vision_session"]
    raw = json.loads(vision.read_text(encoding="utf-8"))
    raw["sync_landmarks"] = raw["sync_landmarks"][:2]
    vision.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="at least three"):
        validate_indo_board_pipeline_spec(spec)


def test_pipeline_preflight_rejects_missing_watch_sync_receipt(
    tmp_path,
):
    spec, document, _rig = _fixture(tmp_path)
    watch = tmp_path / document["watch_journal"]
    events = watch.read_text(encoding="utf-8").splitlines()
    watch.write_text(
        "\n".join(events[:2]) + "\n",
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="Watch journal is missing sealed SYNC receipts",
    ):
        validate_indo_board_pipeline_spec(spec)


def test_pipeline_preflight_rejects_duplicate_watch_sync_receipt(
    tmp_path,
):
    spec, document, _rig = _fixture(tmp_path)
    watch = tmp_path / document["watch_journal"]
    events = watch.read_text(encoding="utf-8").splitlines()
    watch.write_text(
        "\n".join([*events, events[0]]) + "\n",
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="duplicate sealed SYNC receipts",
    ):
        validate_indo_board_pipeline_spec(spec)


def test_failed_preflight_creates_no_output_directory(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    missing = tmp_path / document["iphone"]["video"]
    missing.unlink()
    output = tmp_path / "derived"

    with pytest.raises(FileNotFoundError, match="iphone.video"):
        process_indo_board_pipeline(spec, output)

    assert not output.exists()



@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf")])
def test_pipeline_preflight_rejects_non_finite_threshold(tmp_path, value):
    spec, document, _rig = _fixture(tmp_path)
    document["thresholds"]["maximum_pose_pair_ms"] = value
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match="must be finite"):
        validate_indo_board_pipeline_spec(spec)



def test_pipeline_preflight_rejects_modified_action4_video(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    video = tmp_path / document["action4"]["video"]
    video.write_bytes(video.read_bytes() + b"-modified-after-seal")

    with pytest.raises(
        ValueError,
        match="Action4 video hash does not match",
    ):
        validate_indo_board_pipeline_spec(spec)


def test_pipeline_preflight_rejects_modified_iphone_journal(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    journal = tmp_path / document["iphone"]["journal"]
    journal.write_text(
        journal.read_text(encoding="utf-8") + "{}\n",
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="iPhone journal hash does not match",
    ):
        validate_indo_board_pipeline_spec(spec)



def _state_fixture(tmp_path):
    paths = {}
    for name in (
        "vision.json",
        "watch.jsonl",
        "rig.json",
        "layout.json",
        "iphone-metadata.json",
        "action-metadata.json",
    ):
        path = tmp_path / name
        path.write_text(name + "\n", encoding="utf-8")
        paths[name] = path

    spec_document = {
        "vision_session": paths["vision.json"].name,
        "watch_journal": paths["watch.jsonl"].name,
        "rig_receipt": paths["rig.json"].name,
        "board_marker_layout": paths["layout.json"].name,
        "iphone": {
            "metadata": paths["iphone-metadata.json"].name,
        },
        "action4": {
            "metadata": paths["action-metadata.json"].name,
        },
    }
    spec = tmp_path / "state-spec.json"
    spec.write_text(
        json.dumps(spec_document, sort_keys=True),
        encoding="utf-8",
    )
    return spec, spec_document, paths


def test_pipeline_state_reuses_only_untampered_artifacts(tmp_path):
    spec, spec_document, _paths = _state_fixture(tmp_path)
    state_path = tmp_path / "derived" / "pipeline-state.json"
    state = pipeline_module._initialize_pipeline_state(
        state_path,
        spec_source=spec,
        spec=spec_document,
        resume=False,
    )
    artifact = tmp_path / "derived" / "geometry.json"
    artifact.write_text("sealed-result\n", encoding="utf-8")

    pipeline_module._record_stage(
        state,
        state_path,
        "geometry",
        artifact,
    )

    resumed = pipeline_module._initialize_pipeline_state(
        state_path,
        spec_source=spec,
        spec=spec_document,
        resume=True,
    )
    assert pipeline_module._stage_reusable(
        resumed,
        "geometry",
        artifact,
    )

    artifact.write_text("tampered-result\n", encoding="utf-8")
    assert not pipeline_module._stage_reusable(
        resumed,
        "geometry",
        artifact,
    )


def test_pipeline_state_invalidates_when_authoritative_input_changes(
    tmp_path,
):
    spec, spec_document, paths = _state_fixture(tmp_path)
    state_path = tmp_path / "derived" / "pipeline-state.json"
    state = pipeline_module._initialize_pipeline_state(
        state_path,
        spec_source=spec,
        spec=spec_document,
        resume=False,
    )
    artifact = tmp_path / "derived" / "geometry.json"
    artifact.write_text("sealed-result\n", encoding="utf-8")
    pipeline_module._record_stage(
        state,
        state_path,
        "geometry",
        artifact,
    )

    paths["watch.jsonl"].write_text(
        "different-watch-evidence\n",
        encoding="utf-8",
    )
    resumed = pipeline_module._initialize_pipeline_state(
        state_path,
        spec_source=spec,
        spec=spec_document,
        resume=True,
    )

    assert resumed["stages"] == {}
    assert not pipeline_module._stage_reusable(
        resumed,
        "geometry",
        artifact,
    )
