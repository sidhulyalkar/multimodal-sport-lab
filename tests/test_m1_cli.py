from types import SimpleNamespace

from motionos import cli


def test_validate_observability_cli(monkeypatch, capsys):
    registry = SimpleNamespace(
        schema_version="motionos.observability-registry.v1",
        registry_id="r1",
        sport="longboard",
        variables=(
            SimpleNamespace(
                observability="observable",
                teacher_eligible=True,
            ),
            SimpleNamespace(
                observability="unidentifiable",
                teacher_eligible=False,
            ),
        ),
    )
    monkeypatch.setattr(
        cli,
        "load_observability_registry",
        lambda _path: registry,
    )

    assert cli.main(["validate-observability", "registry.json"]) == 0
    rendered = capsys.readouterr().out
    assert '"teacher_eligible_count": 1' in rendered
    assert '"unidentifiable": 1' in rendered


def test_build_experiment_manifest_cli(monkeypatch, tmp_path, capsys):
    calls = []
    manifest = SimpleNamespace(
        to_dict=lambda: {
            "schema_version": "motionos.experiment-manifest.v1",
            "experiment_id": "exp-1",
        }
    )

    def fake_build(*args):
        calls.append(args)
        return manifest

    monkeypatch.setattr(cli, "build_experiment_manifest", fake_build)
    output = tmp_path / "experiment.json"

    assert (
        cli.main(
            [
                "build-experiment-manifest",
                "spec.json",
                str(output),
            ]
        )
        == 0
    )
    assert calls == [("spec.json", str(output))]
    assert '"experiment_id": "exp-1"' in capsys.readouterr().out


def test_build_grouped_split_cli(monkeypatch, tmp_path, capsys):
    calls = []
    split = SimpleNamespace(
        leakage_check_passed=True,
        to_dict=lambda: {
            "schema_version": "motionos.grouped-split.v1",
            "leakage_check": {"passed": True},
        },
    )

    def fake_split(*args, **kwargs):
        calls.append((args, kwargs))
        return split

    monkeypatch.setattr(cli, "build_grouped_split", fake_split)
    output = tmp_path / "split.json"

    assert (
        cli.main(
            [
                "build-grouped-split",
                "index.json",
                str(output),
                "--group-by",
                "day_id,remount_id",
                "--seed",
                "frozen-v1",
            ]
        )
        == 0
    )
    assert calls == [
        (
            ("index.json", str(output)),
            {
                "group_by": ("day_id", "remount_id"),
                "seed": "frozen-v1",
                "train_fraction": 0.7,
                "validation_fraction": 0.15,
                "purpose": "primary",
            },
        )
    ]
    assert '"passed": true' in capsys.readouterr().out


def test_index_totalcapture_cli(monkeypatch, tmp_path, capsys):
    calls = []

    def fake_index(*args):
        calls.append(args)
        return {
            "schema_version": "motionos.public-totalcapture-index.v1",
            "dataset": "TotalCapture",
            "samples": [{}, {}],
        }

    monkeypatch.setattr(cli, "index_totalcapture", fake_index)
    output = tmp_path / "index.json"

    assert (
        cli.main(
            [
                "index-totalcapture",
                "/data/totalcapture",
                str(output),
            ]
        )
        == 0
    )
    assert calls == [("/data/totalcapture", str(output))]
    assert '"sample_count": 2' in capsys.readouterr().out


def test_verify_experiment_manifest_cli(monkeypatch, capsys):
    monkeypatch.setattr(
        cli,
        "verify_experiment_manifest",
        lambda _path: {
            "schema_version": "motionos.experiment-manifest.v1",
            "experiment_id": "exp-1",
            "passed": True,
        },
    )

    assert cli.main(["verify-experiment-manifest", "experiment.json"]) == 0
    assert '"passed": true' in capsys.readouterr().out


def test_verify_grouped_split_cli(monkeypatch, capsys):
    calls = []

    def fake_verify(*args):
        calls.append(args)
        return {
            "schema_version": "motionos.grouped-split.v1",
            "passed": True,
            "sample_count": 9,
        }

    monkeypatch.setattr(cli, "verify_grouped_split", fake_verify)

    assert (
        cli.main(
            [
                "verify-grouped-split",
                "split.json",
                "index.json",
            ]
        )
        == 0
    )
    assert calls == [("split.json", "index.json")]
    assert '"sample_count": 9' in capsys.readouterr().out
