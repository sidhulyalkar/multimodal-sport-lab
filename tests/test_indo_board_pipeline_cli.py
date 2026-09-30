import json

from motionos import cli


def test_validate_indo_board_vision_spec_cli_is_preflight_only(
    monkeypatch,
    capsys,
):
    calls = []

    def fake_validate(path):
        calls.append(("validate", path))
        return {
            "schema_version": "motionos.indo-board-pipeline-spec.v1"
        }

    def fail_process(*args, **kwargs):
        raise AssertionError("processing pipeline must not run in preflight")

    monkeypatch.setattr(
        cli,
        "validate_indo_board_pipeline_spec",
        fake_validate,
    )
    monkeypatch.setattr(
        cli,
        "process_indo_board_pipeline",
        fail_process,
    )

    status = cli.main(
        [
            "validate-indo-board-vision-spec",
            "pipeline.json",
        ]
    )

    assert status == 0
    assert calls == [("validate", "pipeline.json")]
    output = json.loads(capsys.readouterr().out)
    assert output["valid"] is True
    assert output["schema_version"] == (
        "motionos.indo-board-pipeline-spec.v1"
    )
    assert output["spec"] == "pipeline.json"
