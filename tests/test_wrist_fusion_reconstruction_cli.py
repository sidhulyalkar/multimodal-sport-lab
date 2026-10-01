import json

from motionos import cli


def test_reconstruct_wrist_fusion_calibration_cli(
    monkeypatch,
    capsys,
):
    calls = []

    def fake_reconstruct(spec, output_directory):
        calls.append((spec, output_directory))
        return {
            "schema_version":
                "motionos.wrist-fusion-reconstruction.v1",
            "session_id": "calibration-s1",
            "pose_pair_count": 42,
        }

    monkeypatch.setattr(
        cli,
        "reconstruct_wrist_fusion_calibration",
        fake_reconstruct,
    )

    status = cli.main(
        [
            "reconstruct-wrist-fusion-calibration",
            "reconstruction-spec.json",
            "derived/calibration",
        ]
    )

    assert status == 0
    assert calls == [
        ("reconstruction-spec.json", "derived/calibration")
    ]
    payload = json.loads(capsys.readouterr().out)
    assert payload["pose_pair_count"] == 42
