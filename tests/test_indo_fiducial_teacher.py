import json

from motionos.indo_fiducial_teacher import (
    extract_fiducial_teacher_labels,
)


def _pose_event(
    *,
    session_id: str,
    pose_sequence: int,
    frame_index: int,
    device_time_ns: int,
    provenance: str = "fiducial_measured",
):
    return {
        "schema_version": "motionos.m0.v1",
        "session_id": session_id,
        "device_id": "iphone-camera",
        "stream": "/camera/pose3d",
        "sequence": pose_sequence,
        "device_time_ns": device_time_ns,
        "payload": {
            "source_frame_sequence": frame_index,
            "indo_board_equipment": {
                "model_id": "vision-qr-indo-fiducials-v1",
                "deck": {
                    "left_end": [0.2, 0.7],
                    "right_end": [0.8, 0.7],
                    "confidence": 0.9,
                    "provenance": provenance,
                },
                "roller": {
                    "center": [0.5, 0.72],
                    "confidence": 0.88,
                    "provenance": provenance,
                },
            },
        },
    }


def test_extracts_fiducial_teacher_labels_with_frame_identity(
    tmp_path,
):
    journal = tmp_path / "camera-journal.jsonl"
    events = [
        {
            "stream": "/camera/frame",
            "session_id": "camera-1",
            "sequence": 0,
            "device_time_ns": 1_000_000_000,
            "payload": {},
        },
        _pose_event(
            session_id="camera-1",
            pose_sequence=0,
            frame_index=3,
            device_time_ns=1_100_000_000,
        ),
        _pose_event(
            session_id="camera-1",
            pose_sequence=1,
            frame_index=6,
            device_time_ns=1_200_000_000,
        ),
    ]
    journal.write_text(
        "\n".join(json.dumps(event) for event in events) + "\n",
        encoding="utf-8",
    )
    output = tmp_path / "teacher.json"

    payload = extract_fiducial_teacher_labels(
        journal,
        output,
    )

    assert payload["pose_event_count"] == 2
    assert payload["observation_count"] == 2
    first = payload["observations"][0]
    second = payload["observations"][1]

    assert first["frame_index"] == 3
    assert first["camera_pose_sequence"] == 0
    assert first["device_time_ns"] == 1_100_000_000
    assert first["time_s"] == 0
    assert second["time_s"] == 0.1
    assert (
        first["indo_board_equipment"]["sequence"]
        == 3
    )
    assert (
        first["indo_board_equipment"]["device_time_ns"]
        == 1_100_000_000
    )
    assert output.is_file()


def test_skips_non_fiducial_equipment(tmp_path):
    journal = tmp_path / "camera-journal.jsonl"
    event = _pose_event(
        session_id="camera-1",
        pose_sequence=0,
        frame_index=3,
        device_time_ns=1_100_000_000,
        provenance="model_estimated",
    )
    journal.write_text(
        json.dumps(event) + "\n",
        encoding="utf-8",
    )

    payload = extract_fiducial_teacher_labels(
        journal,
        tmp_path / "teacher.json",
    )

    assert payload["equipment_event_count"] == 1
    assert payload["skipped_non_fiducial_count"] == 1
    assert payload["observation_count"] == 0


def test_invalid_jsonl_fails_with_line_number(tmp_path):
    journal = tmp_path / "camera-journal.jsonl"
    journal.write_text(
        "{}\nnot-json\n",
        encoding="utf-8",
    )

    try:
        extract_fiducial_teacher_labels(
            journal,
            tmp_path / "teacher.json",
        )
    except ValueError as exc:
        assert "line 2" in str(exc)
    else:
        raise AssertionError("expected invalid JSONL to fail")
