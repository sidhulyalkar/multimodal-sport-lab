import json

from motionos import cli


def test_validate_indo_board_acquisition_cli_pass(monkeypatch, capsys):
    calls = []

    def fake_evaluate(
        vision_session,
        iphone_metadata,
        action4_metadata,
        *,
        output_path=None,
    ):
        calls.append(
            (
                vision_session,
                iphone_metadata,
                action4_metadata,
                output_path,
            )
        )
        return {
            "schema_version":
                "motionos.indo-board-acquisition-receipt.v1",
            "profile_id": "m0-indo-board-two-camera-v1",
            "passed": True,
            "failed_check_ids": [],
        }

    monkeypatch.setattr(
        cli,
        "evaluate_indo_board_acquisition",
        fake_evaluate,
    )

    status = cli.main(
        [
            "validate-indo-board-acquisition",
            "vision_session.json",
            "iphone-metadata.json",
            "action4-metadata.json",
            "acquisition-receipt.json",
        ]
    )

    assert status == 0
    assert calls == [
        (
            "vision_session.json",
            "iphone-metadata.json",
            "action4-metadata.json",
            "acquisition-receipt.json",
        )
    ]
    payload = json.loads(capsys.readouterr().out)
    assert payload["passed"] is True


def test_validate_indo_board_acquisition_cli_fails_closed(
    monkeypatch,
    capsys,
):
    monkeypatch.setattr(
        cli,
        "evaluate_indo_board_acquisition",
        lambda *args, **kwargs: {
            "schema_version":
                "motionos.indo-board-acquisition-receipt.v1",
            "profile_id": "m0-indo-board-two-camera-v1",
            "passed": False,
            "failed_check_ids": ["action4_effective_frame_rate"],
        },
    )

    status = cli.main(
        [
            "validate-indo-board-acquisition",
            "vision_session.json",
            "iphone-metadata.json",
            "action4-metadata.json",
            "acquisition-receipt.json",
        ]
    )

    assert status == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["failed_check_ids"] == [
        "action4_effective_frame_rate"
    ]
