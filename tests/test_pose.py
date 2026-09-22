import json

from motionos.pose import align_pose_to_sensor_times, load_body_model
from motionos.schema import SensorEvent


def test_body_model_and_pose_alignment(tmp_path):
    path = tmp_path / "body.json"
    path.write_text(
        json.dumps(
            {
                "model_id": "x",
                "height_m": 1.7,
                "segments_m": {"femur": 0.4},
                "joint_limits_deg": {},
            }
        )
    )
    model = load_body_model(path)
    assert model.segments_m["femur"] == 0.4
    pose = [
        SensorEvent(
            "s",
            "camera",
            "/camera/pose3d",
            0,
            100,
            {"joints_m": {}},
            100,
            1.0,
        )
    ]
    aligned = align_pose_to_sensor_times(pose, [105], tolerance_ns=10)
    assert aligned[0] == pose[0]
