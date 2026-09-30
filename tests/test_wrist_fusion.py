import json

import pytest

from motionos.schema import SensorEvent
from motionos.wrist_fusion import build_wrist_acceleration_fusion


def test_wrist_fusion_recovers_known_acceleration(tmp_path):
    geometry = tmp_path / "geometry.json"
    correspondences = tmp_path / "correspondences.json"
    watch = tmp_path / "watch.jsonl"
    output = tmp_path / "fusion.json"

    points = []
    corr_points = []
    acceleration = 2.0
    for index in range(6):
        time_ns = index * 100_000_000
        time_s = time_ns / 1e9
        x = 0.5 * acceleration * time_s * time_s
        point_id = f"left_wrist_joint-ref-{time_ns}"
        points.append(
            {
                "point_id": point_id,
                "reference_time_ns": time_ns,
                "world_position_m": [x, 1.0, 0.0],
                "mean_reprojection_residual_px": 0.4,
                "timing": {
                    "iphone-rear": {
                        "clock_predictive_std_ms": 1.0,
                    },
                    "dji-action4": {
                        "clock_predictive_std_ms": 1.5,
                    },
                },
            }
        )
        corr_points.append(
            {
                "point_id": point_id,
                "reference_time_ns": time_ns,
                "observations": {
                    "iphone-rear": {"joint_confidence": 0.95},
                    "dji-action4": {"joint_confidence": 0.92},
                },
            }
        )

    geometry.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-geometry-report.v1",
                "points": points,
            }
        ),
        encoding="utf-8",
    )
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "points": corr_points,
            }
        ),
        encoding="utf-8",
    )

    watch_events = [
        SensorEvent(
            session_id="watch-s1",
            device_id="apple-watch",
            stream="/meta/watch",
            sequence=0,
            device_time_ns=0,
            payload={"wrist_location": "left"},
        )
    ]
    for index in range(6):
        watch_events.append(
            SensorEvent(
                session_id="watch-s1",
                device_id="apple-watch",
                stream="/body/watch/imu",
                sequence=index,
                device_time_ns=index * 100_000_000,
                payload={
                    "user_ax": acceleration,
                    "user_ay": 0.0,
                    "user_az": 0.0,
                },
            )
        )
    watch.write_text(
        "\n".join(event.to_json() for event in watch_events) + "\n",
        encoding="utf-8",
    )

    report = build_wrist_acceleration_fusion(
        geometry,
        correspondences,
        watch,
        output,
        watch_acceleration_std_m_s2=0.2,
        vision_acceleration_std_m_s2=0.4,
        maximum_acceleration_rate_m_s3=10.0,
        maximum_time_delta_ms=5.0,
    )

    assert report["wrist_side"] == "left"
    assert report["sample_count"] == 4
    assert report["watch_minus_vision_rms_m_s2"] == pytest.approx(
        0.0,
        abs=1e-9,
    )
    for sample in report["samples"]:
        assert sample["vision_m_s2"] == pytest.approx(
            acceleration,
            abs=1e-9,
        )
        assert sample["watch_m_s2"] == pytest.approx(acceleration)
        assert sample["fused_m_s2"] == pytest.approx(
            acceleration,
            abs=1e-9,
        )
