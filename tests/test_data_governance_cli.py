from motionos import cli


def test_validate_public_export_cli(monkeypatch, capsys):
    calls = []

    def fake_validate(path):
        calls.append(path)
        return {
            "schema_version": "motionos.public-export.v1",
            "export_id": "export-1",
            "passed": True,
            "artifact_count": 2,
        }

    monkeypatch.setattr(cli, "validate_public_export_manifest", fake_validate)

    assert cli.main(["validate-public-export", "export.json"]) == 0
    assert calls == ["export.json"]
    rendered = capsys.readouterr().out
    assert '"passed": true' in rendered
    assert '"artifact_count": 2' in rendered


def test_validate_dataset_registry_cli(monkeypatch, capsys):
    calls = []

    def fake_validate(path):
        calls.append(path)
        return {
            "schema_version": "motionos.external-dataset-registry.v1",
            "passed": True,
            "dataset_count": 1,
        }

    monkeypatch.setattr(
        cli,
        "validate_external_dataset_registry",
        fake_validate,
    )

    assert cli.main(["validate-dataset-registry", "datasets.json"]) == 0
    assert calls == ["datasets.json"]
    assert '"dataset_count": 1' in capsys.readouterr().out
