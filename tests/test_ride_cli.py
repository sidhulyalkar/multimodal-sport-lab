from types import SimpleNamespace

from motionos import cli


def test_first_ride_evidence_only_returns_success_for_complete_evidence(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    report = SimpleNamespace(
        evidence_complete=True,
        qualified=False,
        to_dict=lambda: {
            "evidence_complete": True,
            "qualified": False,
        },
    )

    def fake_build(*args):
        calls.append(args)
        return report

    monkeypatch.setattr(cli, "build_first_ride_report", fake_build)

    output = tmp_path / "report.json"
    rc = cli.main(
        [
            "validate-first-ride",
            "ride-spec.json",
            "--report",
            str(output),
            "--evidence-only",
        ]
    )

    assert rc == 0
    assert calls == [("ride-spec.json", str(output))]
    result = capsys.readouterr().out
    assert '"evidence_complete": true' in result
    assert '"qualified": false' in result


def test_first_ride_full_mode_requires_qualified_verdict(
    monkeypatch,
    tmp_path,
):
    report = SimpleNamespace(
        evidence_complete=True,
        qualified=False,
        to_dict=lambda: {
            "evidence_complete": True,
            "qualified": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "build_first_ride_report",
        lambda *args: report,
    )

    rc = cli.main(
        [
            "validate-first-ride",
            "ride-spec.json",
            "--report",
            str(tmp_path / "report.json"),
        ]
    )

    assert rc == 2


def test_first_ride_full_mode_succeeds_when_qualified(
    monkeypatch,
    tmp_path,
):
    report = SimpleNamespace(
        evidence_complete=True,
        qualified=True,
        to_dict=lambda: {
            "evidence_complete": True,
            "qualified": True,
        },
    )
    monkeypatch.setattr(
        cli,
        "build_first_ride_report",
        lambda *args: report,
    )

    rc = cli.main(
        [
            "validate-first-ride",
            "ride-spec.json",
            "--report",
            str(tmp_path / "report.json"),
        ]
    )

    assert rc == 0
