from __future__ import annotations

import json

from motionos import cli
from motionos.provenance import sha256_file


def _write_profile(tmp_path):
    scan = tmp_path / "scan.glb"
    scan.write_bytes(b"body-scan-fixture")
    profile = tmp_path / "body-model.json"
    profile.write_text(
        json.dumps(
            {
                "schema_version": "motionos.body-model.v2",
                "model_id": "fixture-body",
                "height_m": 1.58,
                "frame_convention": "+X right,+Y up,+Z forward",
                "landmarks_m": {
                    "root": [0.0, 0.0, 0.0],
                    "leftHip": [-0.15, 0.0, 0.0],
                    "rightHip": [0.16, 0.0, 0.0],
                    "leftShoulder": [-0.20, 0.50, 0.0],
                    "rightShoulder": [0.22, 0.51, 0.0],
                },
                "segments_m": {
                    "left_femur": 0.40,
                    "right_femur": 0.42,
                },
                "joint_limits_deg": {},
                "registration_landmarks": [
                    "root",
                    "leftHip",
                    "rightHip",
                    "leftShoulder",
                    "rightShoulder",
                ],
                "source": {
                    "type": "3d_body_scan",
                    "artifact_sha256": sha256_file(scan),
                },
                "metadata": {},
            }
        ),
        encoding="utf-8",
    )
    return profile, scan


def test_validate_body_model_cli_reports_profile_and_asymmetry(
    tmp_path,
    capsys,
):
    profile, scan = _write_profile(tmp_path)

    rc = cli.main(
        [
            "validate-body-model",
            str(profile),
            "--source-artifact",
            str(scan),
        ]
    )

    assert rc == 0
    output = json.loads(capsys.readouterr().out)
    assert output["schema_version"] == "motionos.body-model.v2"
    assert output["model_id"] == "fixture-body"
    assert len(output["profile_sha256"]) == 64
    assert output["source_artifact_sha256"] == sha256_file(scan)
    assert output["registration_landmarks"] == [
        "root",
        "leftHip",
        "rightHip",
        "leftShoulder",
        "rightShoulder",
    ]
    assert output["segments_m"]["left_femur"] == 0.40
    assert output["segments_m"]["right_femur"] == 0.42
    assert (
        output["segments_m"]["left_femur"]
        != output["segments_m"]["right_femur"]
    )


def test_validate_body_model_cli_allows_profile_only(tmp_path, capsys):
    profile, _ = _write_profile(tmp_path)

    rc = cli.main(["validate-body-model", str(profile)])

    assert rc == 0
    output = json.loads(capsys.readouterr().out)
    assert output["source_artifact_sha256"] is None
