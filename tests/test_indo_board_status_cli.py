import json

from motionos import cli


def test_indo_board_status_cli(monkeypatch, capsys):
    calls = []

    def fake_status(
        plan,
        *,
        pipeline_spec_path=None,
        results_directory=None,
    ):
        calls.append(
            (plan, pipeline_spec_path, results_directory)
        )
        return {
            "schema_version": "motionos.indo-board-status.v1",
            "next_action": "Capture the scored session.",
        }

    monkeypatch.setattr(
        cli,
        "build_indo_board_status",
        fake_status,
    )

    status = cli.main(
        [
            "indo-board-status",
            "plan.json",
            "--pipeline",
            "pipeline.json",
            "--results",
            "results/session-001",
        ]
    )

    assert status == 0
    assert calls == [
        ("plan.json", "pipeline.json", "results/session-001")
    ]
    payload = json.loads(capsys.readouterr().out)
    assert payload["schema_version"] == "motionos.indo-board-status.v1"
