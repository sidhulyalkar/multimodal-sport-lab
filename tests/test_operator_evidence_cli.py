from types import SimpleNamespace

from motionos import cli


def test_validate_operator_evidence_cli_passes(monkeypatch, tmp_path, capsys):
    calls = []
    receipt = SimpleNamespace(
        passed=True,
        to_dict=lambda: {
            "run_id": "run-1",
            "passed": True,
            "event_count": 7,
        },
    )

    def fake_write(*args):
        calls.append(args)
        return receipt

    monkeypatch.setattr(
        cli,
        "write_operator_evidence_receipt",
        fake_write,
    )

    output = tmp_path / "receipt.json"
    rc = cli.main(
        [
            "validate-operator-evidence",
            str(tmp_path / "operator"),
            "--receipt",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [
        (
            str(tmp_path / "operator"),
            str(output),
        )
    ]
    rendered = capsys.readouterr().out
    assert '"passed": true' in rendered
    assert '"run_id": "run-1"' in rendered


def test_validate_operator_evidence_cli_fails_closed(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        passed=False,
        to_dict=lambda: {
            "run_id": "run-1",
            "passed": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "write_operator_evidence_receipt",
        lambda *args: receipt,
    )

    rc = cli.main(
        [
            "validate-operator-evidence",
            str(tmp_path / "operator"),
        ]
    )

    assert rc == 2
