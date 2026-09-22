from types import SimpleNamespace

from motionos import cli


def test_derive_clock_sync_forwards_generic_streams_and_peak_keys(
    monkeypatch,
    tmp_path,
    capsys,
):
    calls = []
    receipt = SimpleNamespace(
        coverage=SimpleNamespace(passed=True),
        to_dict=lambda: {
            "schema_version": "motionos.clock-sync.v1",
            "coverage": {"passed": True},
        },
    )

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_clock_sync", fake_write)

    rc = cli.main(
        [
            "derive-clock-sync",
            "reference-session",
            "target-session",
            "windows.json",
            str(tmp_path / "sync.json"),
            "--reference-stream",
            "/body/watch/imu",
            "--target-stream",
            "/body/left_foot/imu",
            "--reference-keys",
            "ax,ay,az",
            "--target-keys",
            "ax, az",
        ]
    )

    assert rc == 0
    assert calls[0][0] == (
        "reference-session",
        "target-session",
        "windows.json",
        str(tmp_path / "sync.json"),
    )
    assert calls[0][1]["reference_stream"] == "/body/watch/imu"
    assert calls[0][1]["target_stream"] == "/body/left_foot/imu"
    assert calls[0][1]["reference_peak_keys"] == ("ax", "ay", "az")
    assert calls[0][1]["target_peak_keys"] == ("ax", "az")
    assert '"passed": true' in capsys.readouterr().out


def test_derive_clock_sync_returns_failure_for_bad_coverage(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        coverage=SimpleNamespace(passed=False),
        to_dict=lambda: {
            "coverage": {"passed": False},
        },
    )
    monkeypatch.setattr(
        cli,
        "write_clock_sync",
        lambda *args, **kwargs: receipt,
    )

    rc = cli.main(
        [
            "derive-clock-sync",
            "reference-session",
            "target-session",
            "windows.json",
            str(tmp_path / "sync.json"),
            "--reference-stream",
            "/body/watch/imu",
            "--target-stream",
            "/equipment/imu/accel",
        ]
    )

    assert rc == 2


def test_build_calibration_bundle_cli(monkeypatch, tmp_path, capsys):
    calls = []
    bundle = SimpleNamespace(
        to_dict=lambda: {
            "schema_version": "motionos.calibration-bundle.v1",
        }
    )

    def fake_build(*args):
        calls.append(args)
        return bundle

    monkeypatch.setattr(cli, "build_calibration_bundle", fake_build)

    output = tmp_path / "calibration.json"
    rc = cli.main(
        [
            "build-calibration-bundle",
            "spec.json",
            str(output),
        ]
    )

    assert rc == 0
    assert calls == [("spec.json", str(output))]
    assert "motionos.calibration-bundle.v1" in capsys.readouterr().out


def test_replay_calibration_cli_prints_bounded_frames(
    monkeypatch,
    capsys,
):
    frames = [
        SimpleNamespace(to_dict=lambda i=i: {"frame": i})
        for i in range(5)
    ]
    calls = []

    def fake_replay(manifest, *, frame_hz):
        calls.append((manifest, frame_hz))
        yield from frames

    monkeypatch.setattr(cli, "replay_calibration_frames", fake_replay)

    rc = cli.main(
        [
            "replay-calibration",
            "calibration.json",
            "--hz",
            "20",
            "--frames",
            "2",
        ]
    )

    assert rc == 0
    assert calls == [("calibration.json", 20.0)]
    output = capsys.readouterr().out
    assert '"frame": 0' in output
    assert '"frame": 1' in output
    assert '"frame": 2' not in output


def test_calibration_gaps_cli(monkeypatch, capsys):
    gaps = [
        SimpleNamespace(
            to_dict=lambda: {
                "role": "equipment",
                "stream": "/equipment/imu/accel",
                "gap_multiple": 5.0,
            }
        )
    ]
    monkeypatch.setattr(
        cli,
        "calibration_gap_regions",
        lambda manifest: tuple(gaps),
    )

    rc = cli.main(["calibration-gaps", "calibration.json"])

    assert rc == 0
    output = capsys.readouterr().out
    assert '"gap_multiple": 5.0' in output
