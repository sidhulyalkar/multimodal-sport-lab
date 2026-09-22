from types import SimpleNamespace

from motionos import cli


def test_import_camera_cli_forwards_evidence_paths(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []

    def fake_import(*args, **kwargs):
        calls.append((args, kwargs))
        return tmp_path / "sessions" / "camera-session"

    monkeypatch.setattr(cli, "import_camera_evidence", fake_import)

    rc = cli.main(
        [
            "import-camera-evidence",
            "camera.jsonl",
            "camera.mov",
            "--metadata",
            "camera-metadata.json",
            "--out",
            str(tmp_path / "sessions"),
            "--sport",
            "longboard",
        ]
    )

    assert rc == 0
    assert calls == [
        (
            (
                "camera.jsonl",
                "camera.mov",
                str(tmp_path / "sessions"),
            ),
            {
                "metadata_path": "camera-metadata.json",
                "sport": "longboard",
            },
        )
    ]
    assert "camera-session" in capsys.readouterr().out


def test_validate_camera_cli_returns_capture_status(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    passing = SimpleNamespace(
        capture_passed=True,
        to_dict=lambda: {
            "protocol": "B5A-camera",
            "capture_passed": True,
        },
    )

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return passing

    monkeypatch.setattr(cli, "write_camera_capture_receipt", fake_write)

    receipt = tmp_path / "receipt.json"
    rc = cli.main(
        [
            "validate-camera",
            "camera-session",
            "--min-duration",
            "600",
            "--receipt",
            str(receipt),
        ]
    )

    assert rc == 0
    assert calls == [
        (
            ("camera-session", str(receipt)),
            {"min_duration_s": 600.0},
        )
    ]
    assert '"capture_passed": true' in capsys.readouterr().out


def test_validate_camera_cli_returns_two_for_failed_capture(
    monkeypatch,
):
    failing = SimpleNamespace(
        capture_passed=False,
        to_dict=lambda: {
            "protocol": "B5A-camera",
            "capture_passed": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "write_camera_capture_receipt",
        lambda *args, **kwargs: failing,
    )

    assert cli.main(["validate-camera", "camera-session"]) == 2
