import json

from motionos.indo_annotations import new_frame_annotation
from motionos.indo_equipment_eval import (
    evaluate_equipment_predictions,
)


def _annotation(
    *,
    source_id: str,
    frame_index: int,
    roller_center_x: float,
    review_status: str,
):
    return new_frame_annotation(
        source_id=source_id,
        frame_index=frame_index,
        time_s=frame_index * 0.1,
        deck_polygon=[
            [0.2, 0.4],
            [0.8, 0.4],
            [0.8, 0.6],
            [0.2, 0.6],
        ],
        deck_left=[0.2, 0.5],
        deck_right=[0.8, 0.5],
        roller_left=[
            roller_center_x - 0.03,
            0.62,
        ],
        roller_right=[
            roller_center_x + 0.03,
            0.62,
        ],
        equipment_confidence=0.9,
        review_status=review_status,
    )


def test_equipment_eval_measures_runtime_relevant_geometry(
    tmp_path,
):
    references = [
        _annotation(
            source_id="video/a",
            frame_index=0,
            roller_center_x=0.50,
            review_status="human_reviewed",
        ),
        _annotation(
            source_id="video/a",
            frame_index=1,
            roller_center_x=0.72,
            review_status="human_corrected",
        ),
    ]
    predictions = [
        _annotation(
            source_id="video/a",
            frame_index=0,
            roller_center_x=0.51,
            review_status="model_proposed",
        ),
        _annotation(
            source_id="video/a",
            frame_index=1,
            roller_center_x=0.69,
            review_status="model_proposed",
        ),
    ]

    reference_path = tmp_path / "reference.json"
    prediction_path = tmp_path / "prediction.json"
    output_path = tmp_path / "evaluation.json"

    reference_path.write_text(
        json.dumps(references),
        encoding="utf-8",
    )
    prediction_path.write_text(
        json.dumps(predictions),
        encoding="utf-8",
    )

    report = evaluate_equipment_predictions(
        reference_path,
        prediction_path,
        output_path,
    )

    assert report["reference_count"] == 2
    assert report["matched_count"] == 2
    assert report["reference_coverage_fraction"] == 1
    assert (
        report["metrics"][
            "roller_center_error_mean"
        ]
        > 0
    )
    assert (
        report["metrics"][
            "roller_along_deck_abs_error_mean"
        ]
        > 0
    )
    assert output_path.is_file()


def test_equipment_eval_does_not_treat_model_labels_as_reference(
    tmp_path,
):
    model_only = [
        _annotation(
            source_id="video/a",
            frame_index=0,
            roller_center_x=0.50,
            review_status="model_proposed",
        )
    ]
    path = tmp_path / "labels.json"
    path.write_text(
        json.dumps(model_only),
        encoding="utf-8",
    )

    report = evaluate_equipment_predictions(
        path,
        path,
    )

    assert report["reference_count"] == 0
    assert report["matched_count"] == 0
    assert report["metrics"] == {}
