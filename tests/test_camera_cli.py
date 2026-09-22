from types import SimpleNamespace

from motionos import cli


def test_import_camera_evidence_cli_forwards_arguments(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []

    def fake_import(*args, **kwargs):
        calls.append((args, kwargs))
        return tmp_path / "sessions" / "camera-fixture"

    monkeypatch.setattr(cli, "import_camera_evidence", fake_import)

    rc = cli.main(
        [
            "import-camera-evidence",
            str(tmp_path / "camera"),
            "--out",
            str(tmp_path / "sessions"),
            "--athlete-id",
            "fixture-athlete",
            "--sport",
            "longboard",
        ]
    )

    assert rc == 0
    assert calls == [
        (
            (
                str(tmp_path / "camera"),
                str(tmp_path / "sessions"),
            ),
            {
                "athlete_id": "fixture-athlete",
                "sport": "longboard",
            },
        )
    ]
    assert "camera-fixture" in capsys.readouterr().out


def test_validate_camera_returns_success_only_for_full_pass(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    receipt = SimpleNamespace(
        passed=True,
        to_dict=lambda: {
            "protocol": "P5A-camera",
            "capture_passed": True,
            "pose_evidence_present": True,
            "passed": True,
        },
    )

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_camera_capture_receipt", fake_write)

    rc = cli.main(
        [
            "validate-camera",
            str(tmp_path / "session"),
            "--min-duration",
            "600",
            "--receipt",
            str(tmp_path / "camera-receipt.json"),
        ]
    )

    assert rc == 0
    assert calls[0][0] == (
        str(tmp_path / "session"),
        str(tmp_path / "camera-receipt.json"),
    )
    assert calls[0][1]["min_duration_s"] == 600.0
    assert '"passed": true' in capsys.readouterr().out


def test_validate_camera_fails_when_pose_evidence_is_not_qualified(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        passed=False,
        to_dict=lambda: {
            "capture_passed": True,
            "pose_evidence_present": False,
            "passed": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "write_camera_capture_receipt",
        lambda *args, **kwargs: receipt,
    )

    rc = cli.main(
        [
            "validate-camera",
            str(tmp_path / "session"),
        ]
    )

    assert rc == 2
