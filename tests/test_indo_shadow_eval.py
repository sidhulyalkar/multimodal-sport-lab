import json

from motionos.indo_shadow_eval import (
    summarize_shadow_equipment_evaluation,
)


def _pose_event(
    *,
    sequence: int,
    frame_index: int,
    roller_error: float,
    center_agreement: bool,
):
    return {
        "session_id": "camera-1",
        "stream": "/camera/pose3d",
        "sequence": sequence,
        "device_time_ns": 1_000_000_000 + sequence * 100_000_000,
        "payload": {
            "source_frame_sequence": frame_index,
            "indo_board_equipment_routing": {
                "schema_version":
                    "motionos.indo-equipment-routing-audit.v1",
                "shadow_comparisons": [
                    {
                        "schema_version":
                            "motionos.indo-equipment-shadow-comparison.v1",
                        "reference_detector_id": "vision_qr",
                        "candidate_detector_id": "markerless",
                        "candidate_model_id": "indo-equipment-v1",
                        "deck_left_error": 0.01,
                        "deck_right_error": 0.02,
                        "deck_endpoint_mean_error": 0.015,
                        "roller_center_error": roller_error,
                        "roller_along_reference_deck_abs_error":
                            roller_error * 2,
                        "center_zone_agreement": center_agreement,
                        "edge_zone_agreement": True,
                        "reference_confidence": 0.90,
                        "candidate_confidence": 0.82,
                    }
                ],
            },
        },
    }


def test_summarizes_shadow_comparisons_by_model(tmp_path):
    journal = tmp_path / "camera-journal.jsonl"
    events = [
        _pose_event(
            sequence=0,
            frame_index=3,
            roller_error=0.02,
            center_agreement=True,
        ),
        _pose_event(
            sequence=1,
            frame_index=6,
            roller_error=0.04,
            center_agreement=False,
        ),
    ]
    journal.write_text(
        "\n".join(json.dumps(event) for event in events) + "\n",
        encoding="utf-8",
    )
    output = tmp_path / "shadow-eval.json"

    report = summarize_shadow_equipment_evaluation(
        journal,
        output,
    )

    assert report["pose_event_count"] == 2
    assert report["routing_event_count"] == 2
    assert report["comparison_count"] == 2
    assert len(report["groups"]) == 1

    group = report["groups"][0]
    assert group["reference_detector_id"] == "vision_qr"
    assert group["candidate_detector_id"] == "markerless"
    assert group["candidate_model_id"] == "indo-equipment-v1"
    assert group["comparison_count"] == 2
    assert (
        group["metrics"]["roller_center_error_mean"]
        == 0.03
    )
    assert (
        group["metrics"]["center_zone_agreement_fraction"]
        == 0.5
    )
    assert output.is_file()


def test_ignores_pose_events_without_shadow_comparison(tmp_path):
    journal = tmp_path / "camera-journal.jsonl"
    events = [
        {
            "session_id": "camera-1",
            "stream": "/camera/pose3d",
            "sequence": 0,
            "device_time_ns": 1,
            "payload": {},
        },
        {
            "session_id": "camera-1",
            "stream": "/camera/frame",
            "sequence": 0,
            "device_time_ns": 1,
            "payload": {},
        },
    ]
    journal.write_text(
        "\n".join(json.dumps(event) for event in events) + "\n",
        encoding="utf-8",
    )

    report = summarize_shadow_equipment_evaluation(
        journal,
    )

    assert report["pose_event_count"] == 1
    assert report["routing_event_count"] == 0
    assert report["comparison_count"] == 0
    assert report["groups"] == []


def test_invalid_jsonl_reports_line_number(tmp_path):
    journal = tmp_path / "camera-journal.jsonl"
    journal.write_text(
        "{}\nnot-json\n",
        encoding="utf-8",
    )

    try:
        summarize_shadow_equipment_evaluation(
            journal,
        )
    except ValueError as exc:
        assert "line 2" in str(exc)
    else:
        raise AssertionError("expected invalid JSONL to fail")
