import json

import pytest

from motionos.indo_annotations import (
    build_annotation_queue,
    equipment_payload_from_frame_annotation,
    export_equipment_observations,
    new_frame_annotation,
    validate_frame_annotation,
)


def test_annotation_queue_groups_creator_splits(tmp_path):
    catalog = tmp_path / "catalog.json"
    catalog.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "source_id": "youtube/a",
                        "source_url": "https://www.youtube.com/watch?v=a",
                        "creator": "INDOBOARD",
                        "rights_status": "platform_only",
                        "retention_policy": "derived_only",
                        "weak_labels": ["official", "tutorial"],
                    },
                    {
                        "source_id": "youtube/b",
                        "source_url": "https://www.youtube.com/watch?v=b",
                        "creator": "INDOBOARD",
                        "rights_status": "platform_only",
                        "retention_policy": "derived_only",
                        "weak_labels": ["official", "tricks"],
                    },
                    {
                        "source_id": "youtube/c",
                        "source_url": "https://www.youtube.com/watch?v=c",
                        "creator": "Community",
                        "rights_status": "unknown",
                        "retention_policy": "derived_only",
                        "weak_labels": ["community"],
                    },
                ]
            }
        ),
        encoding="utf-8",
    )

    output = tmp_path / "queue.json"
    payload = build_annotation_queue(
        catalog,
        "configs/indo_skill_taxonomy.v1.json",
        output,
    )

    assert payload["task_count"] == 3
    official = [
        task
        for task in payload["tasks"]
        if task["creator"] == "INDOBOARD"
    ]
    assert len({task["split"] for task in official}) == 1
    assert official[0]["priority"] > payload["tasks"][-1]["priority"]
    assert output.is_file()


def test_frame_annotation_round_trips_validation():
    annotation = new_frame_annotation(
        source_id="youtube/demo",
        frame_index=12,
        time_s=0.4,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[0.45, 0.62],
        roller_right=[0.55, 0.62],
        equipment_confidence=0.9,
        events=["recovery"],
        skill_labels=["controlled_side_shift"],
        model_id="grounded-sam2-proposal",
    )

    validate_frame_annotation(annotation)
    assert annotation["review"]["status"] == "model_proposed"
    assert annotation["equipment"]["deck"]["confidence"] == 0.9


def test_frame_annotation_rejects_out_of_bounds_geometry():
    annotation = new_frame_annotation(
        source_id="youtube/demo",
        frame_index=12,
        time_s=0.4,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[0.45, 0.62],
        roller_right=[0.55, 0.62],
        equipment_confidence=0.9,
    )
    annotation["equipment"]["roller"]["right"] = [1.2, 0.6]

    with pytest.raises(ValueError, match="normalized"):
        validate_frame_annotation(annotation)


def test_reviewed_annotation_maps_to_runtime_equipment_contract():
    annotation = new_frame_annotation(
        source_id="youtube/demo",
        frame_index=12,
        time_s=0.4,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[0.45, 0.62],
        roller_right=[0.55, 0.62],
        equipment_confidence=0.9,
        review_status="human_corrected",
        model_id="sam2-proposal",
    )

    payload = equipment_payload_from_frame_annotation(
        annotation
    )
    equipment = payload["indo_board_equipment"]

    assert equipment["sequence"] == 12
    assert equipment["device_time_ns"] == 400_000_000
    assert equipment["deck"]["left_end"] == [0.2, 0.5]
    assert equipment["roller"]["center"] == [0.5, 0.62]
    assert (
        equipment["roller"]["provenance"]
        == "manual_annotated"
    )


def test_export_equipment_observations_fails_closed_on_unreviewed(
    tmp_path,
):
    reviewed = new_frame_annotation(
        source_id="youtube/reviewed",
        frame_index=1,
        time_s=0.1,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[0.45, 0.62],
        roller_right=[0.55, 0.62],
        equipment_confidence=0.9,
        review_status="human_reviewed",
    )
    proposed = new_frame_annotation(
        source_id="youtube/proposed",
        frame_index=2,
        time_s=0.2,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[0.40, 0.62],
        roller_right=[0.50, 0.62],
        equipment_confidence=0.7,
        review_status="model_proposed",
    )

    source = tmp_path / "annotations.json"
    source.write_text(
        json.dumps([reviewed, proposed]),
        encoding="utf-8",
    )
    output = tmp_path / "equipment.json"

    payload = export_equipment_observations(
        source,
        output,
    )

    assert payload["observation_count"] == 1
    assert payload["skipped_unreviewed_count"] == 1
    assert (
        payload["observations"][0]["review_status"]
        == "human_reviewed"
    )
    assert output.is_file()
