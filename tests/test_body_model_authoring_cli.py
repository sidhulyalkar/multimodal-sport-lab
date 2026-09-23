from __future__ import annotations

import json
from types import SimpleNamespace

from motionos import cli


def test_build_body_model_cli(monkeypatch, tmp_path, capsys):
    calls = []
    profile = SimpleNamespace(
        schema_version="motionos.body-model.v2",
        model_id="body-1",
        profile_sha256="a" * 64,
        source=SimpleNamespace(artifact_sha256="b" * 64),
        segments_m={
            "left_femur": 0.40,
            "right_femur": 0.42,
        },
    )

    def fake_build(*args):
        calls.append(args)
        return profile

    monkeypatch.setattr(cli, "build_body_model_profile", fake_build)

    output = tmp_path / "body-model.json"
    rc = cli.main(
        [
            "build-body-model",
            "body-authoring.json",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [("body-authoring.json", str(output))]
    rendered = json.loads(capsys.readouterr().out)
    assert rendered["model_id"] == "body-1"
    assert rendered["profile_sha256"] == "a" * 64
    assert rendered["source_artifact_sha256"] == "b" * 64
    assert rendered["segments_m"]["left_femur"] == 0.40
    assert rendered["segments_m"]["right_femur"] == 0.42


def test_evaluate_body_registration_cli(monkeypatch, tmp_path, capsys):
    calls = []
    report = SimpleNamespace(
        to_dict=lambda: {
            "schema_version":
                "motionos.body-registration-repeatability.v1",
            "counts": {
                "total_pose_frames": 10,
                "successful_registrations": 9,
                "failed_registrations": 1,
            },
        }
    )

    def fake_report(*args):
        calls.append(args)
        return report

    monkeypatch.setattr(
        cli,
        "write_registration_repeatability_report",
        fake_report,
    )

    output = tmp_path / "repeatability.json"
    rc = cli.main(
        [
            "evaluate-body-registration",
            "body-model.json",
            "camera-session",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [
        (
            "body-model.json",
            "camera-session",
            str(output),
        )
    ]
    rendered = json.loads(capsys.readouterr().out)
    assert (
        rendered["schema_version"]
        == "motionos.body-registration-repeatability.v1"
    )
    assert rendered["counts"]["successful_registrations"] == 9
