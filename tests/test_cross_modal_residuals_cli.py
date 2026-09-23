from motionos import cli


def test_cross_modal_residual_cli(monkeypatch, tmp_path, capsys):
    calls = []

    def fake_build(*args):
        calls.append(args)
        return {
            "schema_version": "motionos.cross-modal-residual-report.v1",
            "experiment_id": "fixture",
            "imu_video": [],
            "pressure_video": [],
        }

    monkeypatch.setattr(
        cli,
        "build_cross_modal_residual_report",
        fake_build,
    )
    output = tmp_path / "report.json"

    assert (
        cli.main(
            [
                "build-cross-modal-residual-report",
                "spec.json",
                str(output),
            ]
        )
        == 0
    )
    assert calls == [("spec.json", str(output))]
    rendered = capsys.readouterr().out
    assert '"experiment_id": "fixture"' in rendered
