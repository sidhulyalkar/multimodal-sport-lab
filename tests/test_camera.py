from __future__ import annotations

import json
from pathlib import Path

import pytest

from motionos.camera import (
    CAMERA_DROP_STREAM,
    CAMERA_FRAME_STREAM,
    CAMERA_MOTION_STREAM,
    CAMERA_POSE_STREAM,
    build_camera_capture_receipt,
    import_camera_evidence,
)
from motionos.provenance import sha256_file
from motionos.schema import SensorEvent
from motionos.session import SessionReader


def _pose_payload(
    *,
    frame_sequence: int,
    pts_ns: int,
    camera_x_m: float,
) -> dict[str, object]:
    return {
        "joints_root_relative_m": {
            "root": [0.0, 0.0, 0.0],
            "leftWrist": [0.2, 0.5, 0.1],
        },
        "joint_parents": {
            "root": None,
            "leftWrist": "leftElbow",
        },
        "joint_count": 2,
        "body_height_m": 1.8,
        "height_estimation": "reference",
        "camera_origin_matrix": [
            [1.0, 0.0, 0.0, camera_x_m],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 2.0],
            [0.0, 0.0, 0.0, 1.0],
        ],
        "joint_coordinate_frame": "vision_root_joint_relative_meters",
        "camera_origin_semantics": "transform_from_skeleton_root_to_camera",
        "vision_request": "VNDetectHumanBodyPose3DRequest",
        "source_frame_sequence": frame_sequence,
        "source_frame_pts_ns": pts_ns,
        "timestamp_basis": "avcapture_presentation_timestamp",
        "source": "vision_3d_pose_from_camera_frame",
    }


def _frame_payload(
    sequence: int,
    *,
    pose_status: str,
    include_intrinsic: bool,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "frame_index": sequence,
        "pts_seconds": float(sequence + 1),
        "timestamp_basis": "avcapture_presentation_timestamp",
        "source": "avcapture_video_data_output",
        "video_written": True,
        "pose_status": pose_status,
        "pose_stride": 3,
        "vision_orientation": "up",
        "orientation_policy": "rear_camera_native_landscape",
        "width_px": 1920,
        "height_px": 1080,
    }
    if include_intrinsic:
        payload["camera_intrinsic_matrix"] = [
            [1000.0, 0.0, 960.0],
            [0.0, 1000.0, 540.0],
            [0.0, 0.0, 1.0],
        ]
        payload["intrinsic_reference_width_px"] = 1920
        payload["intrinsic_reference_height_px"] = 1080
    return payload


def _write_camera_bundle(
    directory: Path,
    *,
    include_intrinsic: bool = True,
    broken_pose_link: bool = False,
    frame_sequences: tuple[int, ...] = (0, 1, 2),
) -> Path:
    directory.mkdir(parents=True)
    video = directory / "camera.mov"
    journal = directory / "camera-frames.jsonl"
    metadata = directory / "camera-metadata.json"

    video.write_bytes(b"fixture-camera-movie-bytes")

    session_id = "camera-fixture"
    device_id = "camera-device-001"
    pts_by_sequence = {
        0: 1_000_000_000,
        1: 2_000_000_000,
        2: 3_000_000_000,
        3: 4_000_000_000,
    }

    events: list[SensorEvent] = []
    for sequence in frame_sequences:
        status = "detected" if sequence in {0, 2} else "not_scheduled"
        events.append(
            SensorEvent(
                session_id=session_id,
                device_id=device_id,
                stream=CAMERA_FRAME_STREAM,
                sequence=sequence,
                device_time_ns=pts_by_sequence[sequence],
                payload=_frame_payload(
                    sequence,
                    pose_status=status,
                    include_intrinsic=include_intrinsic,
                ),
            )
        )

    for pose_sequence, frame_sequence in enumerate((0, 2)):
        source_sequence = (
            99 if broken_pose_link and frame_sequence == 2 else frame_sequence
        )
        events.append(
            SensorEvent(
                session_id=session_id,
                device_id=device_id,
                stream=CAMERA_POSE_STREAM,
                sequence=pose_sequence,
                device_time_ns=pts_by_sequence[frame_sequence],
                payload=_pose_payload(
                    frame_sequence=source_sequence,
                    pts_ns=pts_by_sequence[frame_sequence],
                    camera_x_m=0.1 * pose_sequence,
                ),
            )
        )

    events.append(
        SensorEvent(
            session_id=session_id,
            device_id=device_id,
            stream=CAMERA_DROP_STREAM,
            sequence=0,
            device_time_ns=2_500_000_000,
            payload={
                "timestamp_basis": "avcapture_presentation_timestamp",
                "source": "AVCaptureVideoDataOutput.didDrop",
                "reason": "late_or_output_pipeline_drop",
            },
        )
    )

    events.sort(
        key=lambda event: (
            event.device_time_ns,
            event.stream,
            event.sequence,
        )
    )
    journal.write_text(
        "".join(event.to_json() + "\n" for event in events),
        encoding="utf-8",
    )

    frame_events = [
        event
        for event in events
        if event.stream == CAMERA_FRAME_STREAM
    ]
    pose_events = [
        event
        for event in events
        if event.stream == CAMERA_POSE_STREAM
    ]
    metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera.v1",
                "session_id": session_id,
                "host": {
                    "model": "iPhone fixture",
                    "os_version": "26.0",
                },
                "camera": {
                    "unique_id": device_id,
                    "localized_name": "Back Camera",
                    "device_type": "builtInWideAngleCamera",
                    "position": "back",
                    "format_width": 1920,
                    "format_height": 1080,
                    "intrinsic_matrix_delivery_enabled": include_intrinsic,
                },
                "video": {
                    "filename": "camera.mov",
                    "container": "mov",
                    "timestamp_basis":
                        "avcapture_presentation_timestamp",
                },
                "pose": {
                    "request": "VNDetectHumanBodyPose3DRequest",
                    "stride_delivered_frames": 3,
                    "joint_coordinate_frame":
                        "vision_root_joint_relative_meters",
                    "interpolation": "none",
                },
                "counts": {
                    "delivered_frames": len(frame_events),
                    "written_frames": len(frame_events),
                    "writer_backpressure_frames": 0,
                    "avcapture_dropped_frames": 1,
                    "pose_scheduled_frames": 2,
                    "pose_detected_frames": len(pose_events),
                    "pose_no_result_frames": 0,
                    "pose_error_frames": 0,
                },
                "pts_ns": {
                    "first": frame_events[0].device_time_ns,
                    "last": frame_events[-1].device_time_ns,
                },
                "first_intrinsic_matrix": (
                    _frame_payload(
                        0,
                        pose_status="detected",
                        include_intrinsic=True,
                    )["camera_intrinsic_matrix"]
                    if include_intrinsic
                    else None
                ),
                "last_intrinsic_matrix": (
                    _frame_payload(
                        2,
                        pose_status="detected",
                        include_intrinsic=True,
                    )["camera_intrinsic_matrix"]
                    if include_intrinsic
                    else None
                ),
                "provenance": {
                    "camera_mov_sha256": sha256_file(video),
                    "camera_frames_jsonl_sha256": sha256_file(journal),
                },
            }
        ),
        encoding="utf-8",
    )
    return directory


def test_import_camera_evidence_and_derive_motion(tmp_path):
    source = _write_camera_bundle(tmp_path / "camera")
    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )
    reader = SessionReader(session_dir)

    assert set(reader.list_streams()) == {
        CAMERA_DROP_STREAM,
        CAMERA_FRAME_STREAM,
        CAMERA_MOTION_STREAM,
        CAMERA_POSE_STREAM,
    }
    assert reader.manifest.devices[0].device_id == "camera-device-001"
    assert reader.manifest.devices[0].model == "iPhone fixture"
    hashes = reader.manifest.metadata["source_evidence_sha256"]
    assert len(hashes["camera_mov"]) == 64
    assert len(hashes["camera_frames_jsonl"]) == 64
    assert len(hashes["camera_metadata_json"]) == 64

    motion = list(reader.iter_stream(CAMERA_MOTION_STREAM))
    assert len(motion) == 1
    assert motion[0].device_time_ns == 3_000_000_000
    assert motion[0].payload["motion_m"] == pytest.approx(0.1)
    assert motion[0].payload["speed_m_s"] == pytest.approx(0.05)
    assert motion[0].payload["derived"] is True

    receipt = build_camera_capture_receipt(
        reader,
        min_duration_s=2.0,
    )
    assert receipt.capture_passed is True
    assert receipt.pose_evidence_present is True
    assert receipt.passed is True
    assert receipt.delivered_frames == 3
    assert receipt.written_frames == 3
    assert receipt.dropped_frames == 1
    assert receipt.pose_detected_frames == 2
    assert receipt.metadata_mismatches == ()


def test_camera_capture_can_pass_when_intrinsics_are_unavailable(tmp_path):
    source = _write_camera_bundle(
        tmp_path / "camera",
        include_intrinsic=False,
    )
    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is True
    assert receipt.passed is True


def test_tampered_video_hash_blocks_capture_qualification(tmp_path):
    source = _write_camera_bundle(tmp_path / "camera")
    (source / "camera.mov").write_bytes(b"tampered-after-sidecar")

    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is False
    assert (
        "provenance.camera_mov_sha256"
        in receipt.metadata_mismatches
    )


def test_broken_pose_frame_link_blocks_pose_qualification(tmp_path):
    source = _write_camera_bundle(
        tmp_path / "camera",
        broken_pose_link=True,
    )
    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is True
    assert receipt.pose_evidence_present is False
    assert receipt.broken_pose_frame_links == 1
    assert receipt.passed is False


def test_delivered_frame_sequence_gap_is_not_silently_accepted(tmp_path):
    source = _write_camera_bundle(
        tmp_path / "camera",
        frame_sequences=(0, 2, 3),
    )
    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=3.0,
    )

    assert receipt.frame_qc.missing_sequences == 1
    assert receipt.capture_passed is False


def test_camera_motion_stream_can_drive_generic_clock_sync(tmp_path):
    source = _write_camera_bundle(tmp_path / "camera")
    session_dir = import_camera_evidence(
        source,
        tmp_path / "sessions",
    )

    motion = list(
        SessionReader(session_dir).iter_stream(CAMERA_MOTION_STREAM)
    )
    assert motion[0].payload["motion_m"] > 0
