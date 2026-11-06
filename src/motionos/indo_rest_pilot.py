"""Descriptive, quality-gated within-rider rest experiment for INDO BOARD.

This module does not infer fatigue, autonomic recovery, injury risk, or rest needs.
Its inputs are independently verified, per-bout aggregates from the existing
MotionOS capture and board-state pipeline. The caller owns source verification.
"""

from __future__ import annotations

import math
import re
import statistics
from itertools import pairwise
from collections import defaultdict
from collections.abc import Mapping, Sequence
from typing import Any

SCHEMA_VERSION = "motionos.indo-rest-pilot.v1"
PHASES = ("reference", "late", "post_rest")
CONTEXT_FIELDS = ("skill_id", "setup_id", "stance_id", "tracking_mode")
# Engineering eligibility threshold, NOT a calibrated clinical probability.
MIN_METRIC_CONFIDENCE = 0.75
METRIC_RANGES = {
    "center_time_fraction": (0.0, 1.0),
    "roller_excursion_p90": (0.0, 1.0),
    "deck_angle_abs_p90_deg": (0.0, 180.0),
}


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    out = float(value)
    return out if math.isfinite(out) else None


def _parse_bout(bout: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(bout, Mapping):
        raise TypeError("every bout must be an object")
    bout_id = bout.get("bout_id")
    phase = bout.get("phase")
    if not isinstance(bout_id, str) or not bout_id.strip():
        raise ValueError("bout_id must be nonempty")
    if phase not in PHASES:
        raise ValueError(f"invalid phase in {bout_id}")
    start = _number(bout.get("start_s"))
    end = _number(bout.get("end_s"))
    if start is None or end is None or start < 0 or end <= start:
        raise ValueError(f"invalid interval in {bout_id}")
    context = bout.get("context")
    if not isinstance(context, Mapping):
        raise TypeError(f"missing context in {bout_id}")
    for field in CONTEXT_FIELDS:
        if not isinstance(context.get(field), str) or not context[field].strip():
            raise ValueError(f"missing context.{field} in {bout_id}")
    effort = bout.get("effort_0_10")
    if effort is not None and (_number(effort) is None or not 0 <= effort <= 10):
        raise ValueError(f"invalid effort_0_10 in {bout_id}")
    metrics = bout.get("metrics")
    confidence = bout.get("confidence")
    if not isinstance(metrics, Mapping) or not isinstance(confidence, Mapping):
        raise TypeError(f"metrics and confidence maps required in {bout_id}")
    return {
        "bout_id": bout_id,
        "phase": phase,
        "start_s": start,
        "end_s": end,
        "context": {name: context[name] for name in CONTEXT_FIELDS},
        "source_verified": bout.get("source_verified") is True,
        "source_digest_sha256": bout.get("source_digest_sha256"),
        "metrics": dict(metrics),
        "confidence": dict(confidence),
        "effort_0_10": effort,
    }


def _eligible(bout: Mapping[str, Any]) -> str | None:
    # source_verified is asserted by the upstream evidence verification stage,
    # not cryptographically checked by this module.
    digest = bout["source_digest_sha256"]
    if not bout["source_verified"] or not isinstance(digest, str) or not re.fullmatch(
        r"[0-9a-fA-F]{64}", digest
    ):
        return "source_not_verified"
    if bout["context"]["tracking_mode"] != "board_roller":
        return "board_metrics_not_supported_by_tracking_mode"
    if not any(
        _valid_metric(bout, metric) is not None for metric in METRIC_RANGES
    ):
        return "no_qualified_board_metrics"
    return None


def _valid_metric(bout: Mapping[str, Any], metric: str) -> float | None:
    value = _number(bout["metrics"].get(metric))
    quality = _number(bout["confidence"].get(metric))
    low, high = METRIC_RANGES[metric]
    if (
        value is None
        or quality is None
        or not low <= value <= high
        or not MIN_METRIC_CONFIDENCE <= quality <= 1.0
    ):
        return None
    return value


def _median_metric(bouts: Sequence[dict[str, Any]], metric: str) -> tuple[float, int] | None:
    values = [v for bout in bouts if (v := _valid_metric(bout, metric)) is not None]
    if len(values) < 2:
        return None
    return statistics.median(values), len(values)


def build_indo_rest_pilot_report(
    *, session_id: str, bouts: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    """Summarize matched reference, late, and optional post-rest attempt groups.

    Explicit phases are assigned by a human-reviewed protocol; this function
    does not infer rest windows or infer causality from changes.
    """
    if not isinstance(session_id, str) or not session_id.strip():
        raise ValueError("session_id must be nonempty")
    if not isinstance(bouts, (list, tuple)):
        raise TypeError("bouts must be an ordered list")
    parsed = [_parse_bout(raw) for raw in bouts]
    ids = [bout["bout_id"] for bout in parsed]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate bout_id")
    ordered = sorted(parsed, key=lambda b: b["start_s"])
    if any(a["end_s"] > b["start_s"] for a, b in pairwise(ordered)):
        raise ValueError("overlapping bout intervals")

    excluded: list[dict[str, str]] = []
    groups: dict[tuple[str, ...], list[dict[str, Any]]] = defaultdict(list)
    for bout in ordered:
        reason = _eligible(bout)
        if reason:
            excluded.append({"bout_id": bout["bout_id"], "reason": reason})
            continue
        key = tuple(bout["context"][name] for name in CONTEXT_FIELDS)
        groups[key].append(bout)

    comparisons = []
    for key, group in sorted(groups.items()):
        phases = {phase: [b for b in group if b["phase"] == phase] for phase in PHASES}
        if len(phases["reference"]) < 2 or len(phases["late"]) < 2:
            continue
        if phases["reference"][-1]["end_s"] > phases["late"][0]["start_s"]:
            continue
        if phases["post_rest"] and (
            phases["late"][-1]["end_s"] > phases["post_rest"][0]["start_s"]
        ):
            continue

        results: dict[str, dict[str, float | int | None]] = {}
        for metric in METRIC_RANGES:
            before = _median_metric(phases["reference"], metric)
            late = _median_metric(phases["late"], metric)
            if before is None or late is None:
                continue
            after = _median_metric(phases["post_rest"], metric)
            results[metric] = {
                "reference_median": before[0],
                "late_median": late[0],
                "late_minus_reference": late[0] - before[0],
                "post_rest_median": after[0] if after else None,
                "post_rest_minus_late": after[0] - late[0] if after else None,
                "n_reference": before[1],
                "n_late": late[1],
                "n_post_rest": after[1] if after else 0,
            }
        if not results:
            continue
        efforts = {
            phase: (
                statistics.median([b["effort_0_10"] for b in subset if b["effort_0_10"] is not None])
                if any(b["effort_0_10"] is not None for b in subset)
                else None
            )
            for phase, subset in phases.items()
        }
        comparisons.append(
            {
                "context": dict(zip(CONTEXT_FIELDS, key)),
                "bout_ids_by_phase": {
                    phase: [b["bout_id"] for b in subset] for phase, subset in phases.items()
                },
                "metrics": results,
                "reported_effort_median_by_phase": efforts,
                "interpretation": "descriptive_only_not_a_fatigue_diagnosis",
            }
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "session_id": session_id,
        "status": "descriptive_only" if comparisons else "insufficient_comparable_evidence",
        "comparisons": comparisons,
        "excluded_bouts": excluded,
        "claim_boundary": (
            "Describes within-session changes in qualified equipment-relative metrics. "
            "Does not measure center of pressure, muscle fatigue, injury risk, "
            "or a validated need for rest. Externally asserted source verification "
            "must be independently enforced by the session ingestion layer."
        ),
    }
