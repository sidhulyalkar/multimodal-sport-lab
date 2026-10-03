import json

from motionos.indo_runtime_equipment_eval import (
    evaluate_runtime_equipment_predictions,
)


def _observation(
    *,
    source_id: str,
    frame_index: int,
    deck_left: list[float],
    deck_right: list[float],
    roller_center: list[float],
    review_status: str,
):
    return {
        "source_id": source_id,
        "frame_index": frame_index,
        "review_status": review_status,
        "indo_board_equipment": {
            "model_id": "test",
            "deck": {
                "left_end": deck_left,
                "right_end": deck_right,
                "confidence": 0.9,
                "provenance": (
                    "fiducial_measured"
                    if review_status == "fiducial_teacher"
                    else "model_estimated"
                ),
            },
            "roller": {
                "center": roller_center,
                "confidence": 0.9,
                "provenance": (
                    "fiducial_measured"
                    if review_status == "fiducial_teacher"
                    else "model_estimated"
                ),
            },
        },
    }


def test_runtime_eval_accepts_center_only_qr_teacher_labels(
    tmp_path,
):
    reference = [
        _observation(
            source_id="camera-1",
            frame_index=3,
            deck_left=[0.2, 0.7],
            deck_right=[0.8, 0.7],
            roller_center=[0.5, 0.7],
            review_status="fiducial_teacher",
        ),
        _observation(
            source_id="camera-1",
            frame_index=6,
            deck_left=[0.2, 0.7],
            deck_right=[0.8, 0.7],
            roller_center=[0.72, 0.7],
            review_status="fiducial_teacher",
        ),
    ]
    prediction = [
        _observation(
            source_id="camera-1",
            frame_index=3,
            deck_left=[0.21, 0.70],
            deck_right=[0.79, 0.70],
            roller_center=[0.51, 0.70],
            review_status="model_proposed",
        ),
        _observation(
            source_id="camera-1",
            frame_index=6,
            deck_left=[0.21, 0.70],
            deck_right=[0.79, 0.70],
            roller_center=[0.69, 0.70],
            review_status="model_proposed",
        ),
    ]

    reference_path = tmp_path / "reference.json"
    prediction_path = tmp_path / "prediction.json"
    output_path = tmp_path / "eval.json"
    reference_path.write_text(
        json.dumps({"observations": reference}),
        encoding="utf-8",
    )
    prediction_path.write_text(
        json.dumps({"observations": prediction}),
        encoding="utf-8",
    )

    report = evaluate_runtime_equipment_predictions(
        reference_path,
        prediction_path,
        output_path,
    )

    assert report["reference_count"] == 2
    assert report["prediction_count"] == 2
    assert report["matched_count"] == 2
    assert report["reference_coverage_fraction"] == 1
    assert report["metrics"]["roller_center_error_mean"] > 0
    assert (
        report["metrics"][
            "roller_along_deck_abs_error_mean"
        ]
        > 0
    )
    assert (
        report["metrics"]["center_zone_correct_fraction"]
        == 1
    )
    assert output_path.is_file()


def test_runtime_eval_requires_trusted_reference_status(
    tmp_path,
):
    model_only = [
        _observation(
            source_id="camera-1",
            frame_index=3,
            deck_left=[0.2, 0.7],
            deck_right=[0.8, 0.7],
            roller_center=[0.5, 0.7],
            review_status="model_proposed",
        )
    ]
    path = tmp_path / "model.json"
    path.write_text(
        json.dumps({"observations": model_only}),
        encoding="utf-8",
    )

    report = evaluate_runtime_equipment_predictions(
        path,
        path,
    )

    assert report["reference_count"] == 0
    assert report["matched_count"] == 0
    assert report["metrics"] == {}


def test_runtime_eval_reports_missing_prediction_coverage(
    tmp_path,
):
    reference = [
        _observation(
            source_id="camera-1",
            frame_index=index,
            deck_left=[0.2, 0.7],
            deck_right=[0.8, 0.7],
            roller_center=[0.5, 0.7],
            review_status="fiducial_teacher",
        )
        for index in range(4)
    ]
    prediction = reference[:2]
    for item in prediction:
        item["review_status"] = "model_proposed"

    reference_path = tmp_path / "reference.json"
    prediction_path = tmp_path / "prediction.json"
    reference_path.write_text(
        json.dumps({"observations": reference}),
        encoding="utf-8",
    )
    prediction_path.write_text(
        json.dumps({"observations": prediction}),
        encoding="utf-8",
    )

    report = evaluate_runtime_equipment_predictions(
        reference_path,
        prediction_path,
    )

    assert report["reference_count"] == 4
    assert report["matched_count"] == 2
    assert report["reference_coverage_fraction"] == 0.5
