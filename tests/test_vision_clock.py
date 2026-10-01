import json

import pytest

from motionos.schema import SensorEvent
from motionos.vision_clock import (
    build_vision_clock_bundle,
    load_clock_from_bundle,
)


def _write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def test_clock_bundle_composes_camera_models_into_watch_time(tmp_path):
    vision = tmp_path / "vision.json"
    watch = tmp_path / "watch.jsonl"
    iphone = tmp_path / "iphone.jsonl"
    external = tmp_path / "action-sync.json"
    output = tmp_path / "clock-bundle.json"

    landmarks = []
    watch_events = []
    for index in range(3):
        host = 2_000_000_000 + index * 2_000_000_000
        watch_time = host - 500_000_000
        landmark_id = f"sync-{index}"
        landmarks.append(
            {
                "landmark_id": landmark_id,
                "session_id": "s1",
                "kind": "whole_body_impulse",
                "host_monotonic_time_ns": host,
                "created_at_unix_ms": 1_000 + index,
                "note": None,
            }
        )
        watch_events.append(
            SensorEvent(
                session_id="watch-session",
                device_id="apple-watch",
                stream="/sync/vision_cue",
                sequence=index,
                device_time_ns=watch_time,
                payload={
                    "vision_session_id": "s1",
                    "landmark_id": landmark_id,
                    "cue_kind": "whole_body_impulse",
                },
            )
        )

    _write_json(
        vision,
        {
            "schema_version": "motionos.vision-session.v1",
            "session_id": "s1",
            "sport": "indo_board",
            "capture_mode": "multiview_calibration",
            "created_at_utc": "2026-09-30T22:00:00Z",
            "camera_sources": [],
            "sync_landmarks": landmarks,
            "media_artifacts": [],
            "derived_artifacts": [],
            "coaching_condition": "feedback_disabled",
            "claim_boundary": "",
        },
    )
    watch.write_text(
        "\n".join(event.to_json() for event in watch_events) + "\n",
        encoding="utf-8",
    )

    iphone_events = [
        SensorEvent(
            session_id="s1",
            device_id="iphone-rear",
            stream="/camera/frame",
            sequence=index,
            device_time_ns=1_000_000_000 + index * 1_000_000_000,
            payload={
                "host_monotonic_time_ns":
                    1_200_000_000 + index * 1_000_000_000,
            },
        )
        for index in range(4)
    ]
    iphone.write_text(
        "\n".join(event.to_json() for event in iphone_events) + "\n",
        encoding="utf-8",
    )

    _write_json(
        external,
        {
            "schema_version": "motionos.external-camera-sync.v1",
            "clock_model": {
                "slope": 1.0,
                "intercept_ns": 1_000_000_000,
                "residual_rms_ns": 2_000_000,
                "observations_used": 3,
            },
        },
    )

    result = build_vision_clock_bundle(
        vision,
        watch,
        iphone,
        external,
        output,
    )

    iphone_to_watch = load_clock_from_bundle(
        output,
        "iphone_camera_to_watch",
    )
    action_to_watch = load_clock_from_bundle(
        output,
        "action4_to_watch",
    )

    # Watch time is host time minus 0.5 s.
    assert iphone_to_watch.map(1_000_000_000) == pytest.approx(
        700_000_000,
        abs=10,
    )
    assert action_to_watch.map(1_000_000_000) == pytest.approx(
        1_500_000_000,
        abs=10,
    )
    assert result["canonical_clock"]["source_id"] == "apple-watch"
