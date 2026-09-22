from types import SimpleNamespace

from motionos import cli


def test_build_calibration_run_cli(monkeypatch, tmp_path, capsys):
    calls = []
    run = SimpleNamespace(
        to_dict=lambda: {
            "schema_version": "motionos.calibration-run.v1",
            "run_id": "run-1",
        }
    )

    def fake_build(*args):
        calls.append(args)
        return run

    monkeypatch.setattr(cli, "build_calibration_run", fake_build)

    output = tmp_path / "run.json"
    rc = cli.main(
        [
            "build-calibration-run",
            "run-spec.json",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [("run-spec.json", str(output))]
    assert "motionos.calibration-run.v1" in capsys.readouterr().out


def test_report_calibration_run_cli(monkeypatch, tmp_path, capsys):
    calls = []
    report = {
        "schema_version": "motionos.calibration-report.v1",
        "run_id": "run-1",
        "unresolved_blockers": [],
    }

    def fake_report(*args):
        calls.append(args)
        return report

    monkeypatch.setattr(cli, "write_calibration_report", fake_report)

    output = tmp_path / "report.json"
    rc = cli.main(
        [
            "report-calibration-run",
            "run.json",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [("run.json", str(output))]
    assert "motionos.calibration-report.v1" in capsys.readouterr().out


def test_export_replay_lab_cli(monkeypatch, tmp_path, capsys):
    calls = []
    payload = {
        "schema_version": "motionos.replay-lab.v1",
        "run": {"run_id": "run-1"},
        "frames": [{}, {}, {}],
    }

    def fake_export(*args, **kwargs):
        calls.append((args, kwargs))
        return payload

    monkeypatch.setattr(cli, "write_replay_lab_payload", fake_export)

    output = tmp_path / "session.json"
    rc = cli.main(
        [
            "export-replay-lab",
            "run.json",
            str(output),
            "--hz",
            "20",
        ]
    )

    assert rc == 0
    assert calls == [
        (
            ("run.json", str(output)),
            {"frame_hz": 20.0},
        )
    ]
    rendered = capsys.readouterr().out
    assert '"frames": 3' in rendered
    assert '"run_id": "run-1"' in rendered
