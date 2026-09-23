from motionos import cli


def test_validate_camera_calibration_cli(monkeypatch, capsys):
    calls = []

    def fake_write(*args):
        calls.append(args)
        return {
            "schema_version": "motionos.camera-calibration-receipt.v1",
            "passed": True,
        }

    monkeypatch.setattr(cli, "write_camera_calibration_receipt", fake_write)

    assert (
        cli.main(
            [
                "validate-camera-calibration",
                "camera-calibration.json",
                "--receipt",
                "receipt.json",
            ]
        )
        == 0
    )
    assert calls == [("camera-calibration.json", "receipt.json")]
    assert '"passed": true' in capsys.readouterr().out


def test_build_camera_rig_cli_propagates_gate(monkeypatch, capsys):
    calls = []

    def fake_build(*args):
        calls.append(args)
        return {
            "schema_version": "motionos.camera-rig-receipt.v1",
            "passed": False,
        }

    monkeypatch.setattr(cli, "build_camera_rig_receipt", fake_build)

    assert cli.main(["build-camera-rig", "spec.json", "rig.json"]) == 2
    assert calls == [("spec.json", "rig.json")]
    assert '"passed": false' in capsys.readouterr().out


def test_triangulate_multiview_cli(monkeypatch, capsys):
    calls = []

    def fake_triangulate(*args, **kwargs):
        calls.append((args, kwargs))
        return {
            "schema_version": "motionos.multiview-geometry-report.v1",
            "point_count": 3,
        }

    monkeypatch.setattr(cli, "triangulate_multiview", fake_triangulate)

    assert (
        cli.main(
            [
                "triangulate-multiview",
                "rig.json",
                "points.json",
                "geometry.json",
                "--measurements-output",
                "measurements.json",
            ]
        )
        == 0
    )
    assert calls == [
        (
            ("rig.json", "points.json", "geometry.json"),
            {"measurements_output_path": "measurements.json"},
        )
    ]
    assert '"point_count": 3' in capsys.readouterr().out
