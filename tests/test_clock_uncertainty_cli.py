from motionos import cli


def test_analyze_clock_uncertainty_cli(monkeypatch, tmp_path, capsys):
    calls = []

    def fake_analyze(*args, **kwargs):
        calls.append((args, kwargs))
        return {
            "schema_version": "motionos.clock-uncertainty.v1",
            "weighted_affine": {"drift_ppm": 12.0},
        }

    monkeypatch.setattr(cli, "analyze_clock_uncertainty", fake_analyze)
    output = tmp_path / "analysis.json"

    assert (
        cli.main(
            [
                "analyze-clock-uncertainty",
                "watch",
                "pod",
                "clock.json",
                str(output),
                "--default-uncertainty-ms",
                "2.5",
            ]
        )
        == 0
    )
    assert calls == [
        (
            ("watch", "pod", "clock.json", str(output)),
            {"default_uncertainty_ns": 2_500_000.0},
        )
    ]
    assert '"drift_ppm": 12.0' in capsys.readouterr().out


def test_query_clock_uncertainty_cli(monkeypatch, capsys):
    calls = []

    def fake_query(*args):
        calls.append(args)
        return {
            "mapped_reference_time_ns": 123,
            "predictive_std_ms": 4.2,
            "extrapolated": False,
        }

    monkeypatch.setattr(cli, "query_clock_uncertainty", fake_query)

    assert (
        cli.main(
            [
                "query-clock-uncertainty",
                "analysis.json",
                "1000000",
            ]
        )
        == 0
    )
    assert calls == [("analysis.json", 1_000_000)]
    rendered = capsys.readouterr().out
    assert '"predictive_std_ms": 4.2' in rendered
