import json

from motionos import cli


def test_calibrate_wrist_fusion_cli(monkeypatch, capsys):
    calls = []

    def fake_calibrate(
        geometry,
        correspondences,
        watch,
        spec,
        output,
    ):
        calls.append(
            (
                geometry,
                correspondences,
                watch,
                spec,
                output,
            )
        )
        return {
            "schema_version":
                "motionos.wrist-fusion-calibration.v1",
            "recommended_wrist_fusion": {
                "watch_acceleration_std_m_s2": 0.2,
                "vision_acceleration_std_m_s2": 0.4,
                "maximum_acceleration_rate_m_s3": 10.0,
                "maximum_time_delta_ms": 20.0,
            },
        }

    monkeypatch.setattr(
        cli,
        "calibrate_wrist_fusion",
        fake_calibrate,
    )

    status = cli.main(
        [
            "calibrate-wrist-fusion",
            "geometry.json",
            "correspondences.json",
            "watch.jsonl",
            "calibration-spec.json",
            "calibration-receipt.json",
        ]
    )

    assert status == 0
    assert calls == [
        (
            "geometry.json",
            "correspondences.json",
            "watch.jsonl",
            "calibration-spec.json",
            "calibration-receipt.json",
        )
    ]
    payload = json.loads(capsys.readouterr().out)
    assert payload["schema_version"] == (
        "motionos.wrist-fusion-calibration.v1"
    )
