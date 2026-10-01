import json

from motionos import cli


def test_build_indo_board_qualification_plan_cli(
    monkeypatch,
    capsys,
):
    calls = []

    def fake_build(spec, output):
        calls.append((spec, output))
        return {
            "schema_version":
                "motionos.indo-board-qualification-plan.v1",
            "plan_id": "plan-s1",
            "frozen_before_scored_capture": True,
        }

    monkeypatch.setattr(
        cli,
        "build_indo_board_qualification_plan",
        fake_build,
    )

    status = cli.main(
        [
            "build-indo-board-qualification-plan",
            "plan-spec.json",
            "plan.json",
        ]
    )

    assert status == 0
    assert calls == [("plan-spec.json", "plan.json")]
    payload = json.loads(capsys.readouterr().out)
    assert payload["plan_id"] == "plan-s1"
    assert payload["frozen_before_scored_capture"] is True
