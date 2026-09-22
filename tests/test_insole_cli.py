from types import SimpleNamespace

from motionos import cli


def test_import_opengo_cli_forwards_identity_and_output(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []

    def fake_import(*args, **kwargs):
        calls.append((args, kwargs))
        return tmp_path / "sessions" / "p2-explicit"

    monkeypatch.setattr(cli, "import_opengo_text_export", fake_import)

    rc = cli.main(
        [
            "import-opengo-export",
            str(tmp_path / "input.txt"),
            "--out",
            str(tmp_path / "sessions"),
            "--session-id",
            "p2-explicit",
            "--athlete-id",
            "athlete-fixture",
            "--sport",
            "longboard",
        ]
    )

    assert rc == 0
    assert len(calls) == 1
    assert calls[0][0] == (
        str(tmp_path / "input.txt"),
        str(tmp_path / "sessions"),
    )
    assert calls[0][1] == {
        "session_id": "p2-explicit",
        "athlete_id": "athlete-fixture",
        "sport": "longboard",
    }
    assert "p2-explicit" in capsys.readouterr().out


def test_validate_p2_returns_success_for_capture_pass(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    receipt = SimpleNamespace(
        capture_passed=True,
        to_dict=lambda: {
            "capture_passed": True,
            "protocol": "P2-capture",
        },
    )

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_p2_capture_receipt", fake_write)

    rc = cli.main(
        [
            "validate-p2",
            str(tmp_path / "session"),
            "--min-duration",
            "600",
            "--receipt",
            str(tmp_path / "p2.json"),
        ]
    )

    assert rc == 0
    assert calls[0][0] == (
        str(tmp_path / "session"),
        str(tmp_path / "p2.json"),
    )
    assert calls[0][1]["min_duration_s"] == 600.0
    assert '"capture_passed": true' in capsys.readouterr().out


def test_validate_p2_returns_failure_for_failed_capture(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        capture_passed=False,
        to_dict=lambda: {
            "capture_passed": False,
            "protocol": "P2-capture",
        },
    )
    monkeypatch.setattr(
        cli,
        "write_p2_capture_receipt",
        lambda *args, **kwargs: receipt,
    )

    rc = cli.main(
        [
            "validate-p2",
            str(tmp_path / "session"),
        ]
    )

    assert rc == 2
