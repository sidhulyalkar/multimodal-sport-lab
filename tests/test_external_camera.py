import json

from motionos.external_camera import import_external_camera_evidence
from motionos.provenance import sha256_file
from motionos.schema import SensorEvent
from motionos.session import SessionReader


def test_external_camera_import_preserves_pts_and_provenance(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    video = source / "action4.mov"
    journal = source / "action4-frames.jsonl"
    metadata = source / "action4-derived-metadata.json"
    video.write_bytes(b"fixture-video")

    events = [
        SensorEvent(
            session_id="vision-s1",
            device_id="dji-action4",
            stream="/camera/frame",
            sequence=0,
            device_time_ns=1_000,
            payload={
                "timestamp_basis": "container_video_pts",
                "frame_index": 0,
            },
        ),
        SensorEvent(
            session_id="vision-s1",
            device_id="dji-action4",
            stream="/camera/pose2d",
            sequence=0,
            device_time_ns=1_000,
            payload={
                "timestamp_basis": "container_video_pts",
                "source_frame_sequence": 0,
                "source_frame_pts_ns": 1_000,
            },
        ),
        SensorEvent(
            session_id="vision-s1",
            device_id="dji-action4",
            stream="/camera/frame",
            sequence=1,
            device_time_ns=2_000,
            payload={
                "timestamp_basis": "container_video_pts",
                "frame_index": 1,
            },
        ),
    ]
    journal.write_text(
        "\n".join(event.to_json() for event in events) + "\n",
        encoding="utf-8",
    )
    metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.external-video-pose2d.v1",
                "session_id": "vision-s1",
                "source_id": "dji-action4",
            }
        ),
        encoding="utf-8",
    )

    imported = import_external_camera_evidence(
        journal,
        video,
        metadata,
        tmp_path / "sessions",
    )
    reader = SessionReader(imported)

    assert reader.manifest.session_id == "vision-s1-dji-action4"
    assert reader.manifest.metadata["source_session_id"] == "vision-s1"
    assert reader.manifest.metadata["source_evidence_sha256"][
        "source_video"
    ] == sha256_file(video)

    frames = list(reader.iter_stream("/camera/frame"))
    poses = list(reader.iter_stream("/camera/pose2d"))
    assert [event.device_time_ns for event in frames] == [1_000, 2_000]
    assert frames[0].session_id == "vision-s1-dji-action4"
    assert poses[0].payload["source_frame_pts_ns"] == 1_000
