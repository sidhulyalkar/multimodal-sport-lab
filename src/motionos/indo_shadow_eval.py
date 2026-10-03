from __future__ import annotations

import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

INDO_SHADOW_EVAL_SCHEMA_VERSION = (
    "motionos.indo-shadow-equipment-eval.v1"
)


def summarize_shadow_equipment_evaluation(
    camera_journal_path: str | Path,
    output_path: str | Path | None = None,
) -> dict[str, Any]:
    """Aggregate frame-level QR/human-vs-markerless shadow comparisons.

    The camera runtime emits these comparisons without allowing an
    unqualified model to influence coaching. This function turns that
    evidence stream into one deterministic evaluation report per model /
    detector pair.
    """

    journal = Path(camera_journal_path)
    pose_event_count = 0
    routing_event_count = 0
    rows: list[dict[str, Any]] = []

    with journal.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue

            try:
                envelope = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"invalid JSONL at line {line_number}: {exc.msg}"
                ) from exc

            if not isinstance(envelope, dict):
                continue
            if envelope.get("stream") != "/camera/pose3d":
                continue
            pose_event_count += 1

            payload = envelope.get("payload")
            if not isinstance(payload, dict):
                continue
            routing = payload.get(
                "indo_board_equipment_routing"
            )
            if not isinstance(routing, dict):
                continue
            routing_event_count += 1

            comparisons = routing.get(
                "shadow_comparisons"
            )
            if not isinstance(comparisons, list):
                continue

            for comparison in comparisons:
                parsed = _parse_comparison(
                    comparison,
                    envelope=envelope,
                    payload=payload,
                )
                if parsed is not None:
                    rows.append(parsed)

    grouped: dict[
        tuple[str, str, str],
        list[dict[str, Any]],
    ] = defaultdict(list)
    for row in rows:
        grouped[
            (
                row["reference_detector_id"],
                row["candidate_detector_id"],
                row.get("candidate_model_id") or "",
            )
        ].append(row)

    groups = []
    for key, group_rows in sorted(grouped.items()):
        reference_detector, candidate_detector, model_id = key
        groups.append(
            {
                "reference_detector_id": reference_detector,
                "candidate_detector_id": candidate_detector,
                "candidate_model_id": model_id or None,
                "comparison_count": len(group_rows),
                "metrics": _aggregate(group_rows),
            }
        )

    report = {
        "schema_version":
            INDO_SHADOW_EVAL_SCHEMA_VERSION,
        "source_journal": journal.name,
        "pose_event_count": pose_event_count,
        "routing_event_count": routing_event_count,
        "comparison_count": len(rows),
        "groups": groups,
        "claim_boundary": (
            "This report summarizes normalized image-space shadow agreement "
            "recorded while a trusted reference source was visible. It does "
            "not establish calibrated physical or biomechanics accuracy."
        ),
    }

    if output_path is not None:
        _write_json(output_path, report)
    return report


def _parse_comparison(
    raw: object,
    *,
    envelope: dict[str, Any],
    payload: dict[str, Any],
) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None

    reference_detector = raw.get(
        "reference_detector_id"
    )
    candidate_detector = raw.get(
        "candidate_detector_id"
    )
    if not isinstance(reference_detector, str):
        return None
    if not isinstance(candidate_detector, str):
        return None

    numeric_keys = (
        "deck_left_error",
        "deck_right_error",
        "deck_endpoint_mean_error",
        "roller_center_error",
        "roller_along_reference_deck_abs_error",
        "reference_confidence",
        "candidate_confidence",
    )
    row: dict[str, Any] = {
        "reference_detector_id": reference_detector,
        "candidate_detector_id": candidate_detector,
        "candidate_model_id":
            raw.get("candidate_model_id"),
        "session_id": envelope.get("session_id"),
        "pose_sequence": envelope.get("sequence"),
        "source_frame_sequence":
            payload.get("source_frame_sequence"),
        "device_time_ns":
            envelope.get("device_time_ns"),
    }

    for key in numeric_keys:
        value = raw.get(key)
        if not isinstance(value, (int, float)):
            return None
        number = float(value)
        if not math.isfinite(number):
            return None
        row[key] = number

    for key in (
        "center_zone_agreement",
        "edge_zone_agreement",
    ):
        value = raw.get(key)
        if not isinstance(value, bool):
            return None
        row[key] = value

    return row


def _aggregate(
    rows: list[dict[str, Any]],
) -> dict[str, float]:
    result: dict[str, float] = {}

    error_keys = (
        "deck_left_error",
        "deck_right_error",
        "deck_endpoint_mean_error",
        "roller_center_error",
        "roller_along_reference_deck_abs_error",
    )
    for key in error_keys:
        values = [float(row[key]) for row in rows]
        result[f"{key}_mean"] = statistics.fmean(values)
        result[f"{key}_p90"] = _percentile(
            values,
            0.90,
        )

    for key in (
        "center_zone_agreement",
        "edge_zone_agreement",
    ):
        result[f"{key}_fraction"] = statistics.fmean(
            1.0 if row[key] else 0.0
            for row in rows
        )

    result["reference_confidence_mean"] = statistics.fmean(
        float(row["reference_confidence"])
        for row in rows
    )
    result["candidate_confidence_mean"] = statistics.fmean(
        float(row["candidate_confidence"])
        for row in rows
    )
    return result


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
        json.dumps(payload, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
