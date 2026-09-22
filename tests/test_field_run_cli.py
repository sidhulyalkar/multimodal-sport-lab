from types import SimpleNamespace

from motionos import cli


def test_validate_field_run_cli_returns_success_for_complete_protocol(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    receipt = SimpleNamespace(
        integrity_passed=True,
        protocol_complete=True,
        to_dict=lambda: {
            "run_id": "run-1",
            "integrity_passed": True,
            "protocol_complete": True,
            "clean_run": True,
        },
    )

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_field_run_receipt", fake_write)

    output = tmp_path / "receipt.json"
    rc = cli.main(
        [
            "validate-field-run",
            str(tmp_path / "field-run"),
            "--receipt",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [
        (
            (
                str(tmp_path / "field-run"),
                str(output),
            ),
            {},
        )
    ]
    assert '"protocol_complete": true' in capsys.readouterr().out


def test_validate_field_run_cli_fails_incomplete_protocol(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        integrity_passed=True,
        protocol_complete=False,
        to_dict=lambda: {
            "integrity_passed": True,
            "protocol_complete": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "write_field_run_receipt",
        lambda *args, **kwargs: receipt,
    )

    rc = cli.main(
        [
            "validate-field-run",
            str(tmp_path / "field-run"),
        ]
    )

    assert rc == 2
