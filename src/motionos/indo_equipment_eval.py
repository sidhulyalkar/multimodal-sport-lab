from __future__ import annotations

import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

INDO_EQUIPMENT_EVAL_SCHEMA_VERSION = "motionos.indo-equipment-eval.v1"


def evaluate_equipment_predictions(
    reference_path: str | Path,
    prediction_path: str | Path,
    output_path: str | Path | None = None,
) -> dict[str, Any]:
    """Evaluate image-space deck/roller predictions against reviewed labels."""

    references = _load_annotations(reference_path)
    predictions = _load_annotations(prediction_path)

    ref_by_key = {
        _key(item): item
        for item in references
        if _reviewed(item)
    }
    pred_by_key = {
        _key(item): item
        for item in predictions
        if item.get("review", {}).get("status") != "rejected"
    }

    rows: list[dict[str, Any]] = []
    by_source: dict[str, list[dict[str, float]]] = defaultdict(list)

    for key, reference in ref_by_key.items():
        prediction = pred_by_key.get(key)
        if prediction is None:
            continue

        row = _compare(reference, prediction)
        row["source_id"] = key[0]
        row["frame_index"] = key[1]
        rows.append(row)
        by_source[key[0]].append(row)

    aggregate = _aggregate(rows)
    source_metrics = {
        source_id: _aggregate(source_rows)
        for source_id, source_rows in sorted(by_source.items())
    }

    payload = {
        "schema_version": INDO_EQUIPMENT_EVAL_SCHEMA_VERSION,
        "reference_count": len(ref_by_key),
        "prediction_count": len(pred_by_key),
        "matched_count": len(rows),
        "reference_coverage_fraction": (
            len(rows) / len(ref_by_key)
            if ref_by_key
            else 0.0
        ),
        "metrics": aggregate,
        "by_source": source_metrics,
        "claim_boundary": (
            "These metrics evaluate normalized image-space equipment geometry. "
            "They do not establish calibrated physical accuracy or coaching validity."
        ),
    }

    if output_path is not None:
        _write_json(output_path, payload)
    return payload


def _compare(
    reference: dict[str, Any],
    prediction: dict[str, Any],
) -> dict[str, float]:
    ref_equipment = reference["equipment"]
    pred_equipment = prediction["equipment"]

    ref_deck = ref_equipment["deck"]
    pred_deck = pred_equipment["deck"]
    ref_roller = ref_equipment["roller"]
    pred_roller = pred_equipment["roller"]

    deck_left_error = _distance(
        ref_deck["left"],
        pred_deck["left"],
    )
    deck_right_error = _distance(
        ref_deck["right"],
        pred_deck["right"],
    )
    roller_left_error = _distance(
        ref_roller["left"],
        pred_roller["left"],
    )
    roller_right_error = _distance(
        ref_roller["right"],
        pred_roller["right"],
    )

    ref_roller_center = _midpoint(
        ref_roller["left"],
        ref_roller["right"],
    )
    pred_roller_center = _midpoint(
        pred_roller["left"],
        pred_roller["right"],
    )
    roller_center_error = _distance(
        ref_roller_center,
        pred_roller_center,
    )

    ref_along = _roller_along_deck(
        ref_deck["left"],
        ref_deck["right"],
        ref_roller_center,
    )
    pred_along = _roller_along_deck(
        ref_deck["left"],
        ref_deck["right"],
        pred_roller_center,
    )
    along_error = abs(pred_along - ref_along)

    ref_center = abs(ref_along) <= 0.20
    pred_center = abs(pred_along) <= 0.20
    ref_edge = abs(ref_along) >= 0.75
    pred_edge = abs(pred_along) >= 0.75

    return {
        "deck_endpoint_mean_error": (
            deck_left_error + deck_right_error
        ) / 2,
        "roller_endpoint_mean_error": (
            roller_left_error + roller_right_error
        ) / 2,
        "roller_center_error": roller_center_error,
        "roller_along_deck_abs_error": along_error,
        "center_zone_correct": float(ref_center == pred_center),
        "edge_zone_correct": float(ref_edge == pred_edge),
    }


def _aggregate(
    rows: list[dict[str, Any]],
) -> dict[str, float]:
    if not rows:
        return {}

    numeric_keys = (
        "deck_endpoint_mean_error",
        "roller_endpoint_mean_error",
        "roller_center_error",
        "roller_along_deck_abs_error",
        "center_zone_correct",
        "edge_zone_correct",
    )

    result: dict[str, float] = {}
    for key in numeric_keys:
        values = [
            float(row[key])
            for row in rows
            if isinstance(row.get(key), (int, float))
        ]
        if not values:
            continue
        result[f"{key}_mean"] = statistics.fmean(values)

        if key.endswith("_error"):
            result[f"{key}_p90"] = _percentile(values, 0.90)

    return result


def _load_annotations(
    path: str | Path,
) -> list[dict[str, Any]]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        values = raw.get("annotations")
    else:
        values = raw
    if not isinstance(values, list):
        raise TypeError(
            "equipment evaluation input must be a list or {annotations: [...]}"
        )
    return [
        value
        for value in values
        if isinstance(value, dict)
    ]


def _reviewed(annotation: dict[str, Any]) -> bool:
    return annotation.get("review", {}).get("status") in {
        "human_reviewed",
        "human_corrected",
    }


def _key(
    annotation: dict[str, Any],
) -> tuple[str, int]:
    source_id = annotation.get("source_id")
    frame_index = annotation.get("frame_index")
    if not isinstance(source_id, str) or not source_id:
        raise ValueError("annotation source_id must be non-empty")
    if not isinstance(frame_index, int) or frame_index < 0:
        raise ValueError(
            "annotation frame_index must be a non-negative integer"
        )
    return source_id, frame_index


def _distance(
    first: list[float],
    second: list[float],
) -> float:
    return math.hypot(
        float(first[0]) - float(second[0]),
        float(first[1]) - float(second[1]),
    )


def _midpoint(
    first: list[float],
    second: list[float],
) -> list[float]:
    return [
        (float(first[0]) + float(second[0])) / 2,
        (float(first[1]) + float(second[1])) / 2,
    ]


def _roller_along_deck(
    deck_left: list[float],
    deck_right: list[float],
    roller_center: list[float],
) -> float:
    dx = float(deck_right[0]) - float(deck_left[0])
    dy = float(deck_right[1]) - float(deck_left[1])
    length_squared = dx * dx + dy * dy
    if length_squared <= 1e-9:
        raise ValueError("deck endpoints are degenerate")

    rel_x = float(roller_center[0]) - float(deck_left[0])
    rel_y = float(roller_center[1]) - float(deck_left[1])
    projection = (
        rel_x * dx + rel_y * dy
    ) / length_squared
    return (projection - 0.5) * 2


def _percentile(
    values: list[float],
    quantile: float,
) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    position = (
        len(ordered) - 1
    ) * min(1.0, max(0.0, quantile))
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return (
        ordered[lower] * (1 - fraction)
        + ordered[upper] * fraction
    )


def _write_json(
    path: str | Path,
    payload: dict[str, Any],
) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
