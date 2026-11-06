"""Verify and decode optional INDO rest annotations from an operator journal.

This is the host-annotation timeline, NOT authoritative camera/Watch alignment.
Evidence for movement features must be qualified separately.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "motionos.indo-rest-event-extract.v1"
SOURCE_SCHEMA = "motionos.operator-events.v1"
EVENT_SCHEMA = "motionos.indo-rest-events.v1"
TIMING_SEMANTICS = "annotation_only_not_sync_authority"
MARKERS = {
    "indo_rest_bout_started",
    "indo_rest_bout_finished",
    "indo_rest_rest_started",
    "indo_rest_rest_finished",
    "indo_rest_effort_reported",
}
CONTEXT_KEYS = ("skill_id", "setup_id", "stance_id", "tracking_mode")
PHASES = ("reference", "late", "post_rest")


class OperatorEvidenceError(ValueError):
    """Untrusted or inconsistent operator evidence."""


def _nonempty(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise OperatorEvidenceError(f"{name} must be a non-empty string")
    return value


def _ns(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise OperatorEvidenceError(f"{name} must be a nonnegative integer")
    return value


def extract_indo_rest_events(
    operator_journal: str | Path, *, run_id: str, expected_sha256: str
) -> dict[str, Any]:
    """Require a trusted expected digest; return descriptive bout annotation evidence.

    The caller must independently establish that expected_sha256 came from a
    trusted, sealed session manifest. Comparing a digest supplied by the same
    untrusted journal is not authenticity validation.
    """
    run_id = _nonempty(run_id, "run_id")
    if not isinstance(expected_sha256, str) or not re.fullmatch(
        r"[0-9a-fA-F]{64}", expected_sha256
    ):
        raise OperatorEvidenceError("expected_sha256 must be a SHA-256 hex digest")
    data = Path(operator_journal).read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256.lower():
        raise OperatorEvidenceError("operator journal digest mismatch")

    events: list[dict[str, Any]] = []
    for line_number, line in enumerate(data.splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise OperatorEvidenceError(f"invalid JSONL at line {line_number}") from exc
        if not isinstance(item, dict):
            raise OperatorEvidenceError("operator event must be a JSON object")
        if item.get("schema_version") != SOURCE_SCHEMA or item.get("run_id") != run_id:
            raise OperatorEvidenceError(f"wrong source schema or run at line {line_number}")
        if item.get("timing_semantics") != TIMING_SEMANTICS:
            raise OperatorEvidenceError(f"unqualified clock semantics at line {line_number}")
        sequence = _ns(item.get("sequence"), "sequence")
        host_ns = _ns(item.get("host_monotonic_ns"), "host_monotonic_ns")
        if sequence != len(events):
            raise OperatorEvidenceError("operator journal has a sequence gap or duplicate")
        if events and host_ns < events[-1]["host_monotonic_ns"]:
            raise OperatorEvidenceError("host monotonic clock moved backwards")
        if not isinstance(item.get("kind"), str):
            raise OperatorEvidenceError("operator event kind is missing")
        events.append(item)
    starts = [i for i, e in enumerate(events) if e["kind"] == "run_started"]
    if len(starts) != 1:
        raise OperatorEvidenceError("exactly one run_started event is required")
    start_index = starts[0]
    start_ns = events[start_index]["host_monotonic_ns"]
    seal_indices = [i for i, e in enumerate(events) if e["kind"] == "run_sealed"]
    if len(seal_indices) > 1 or (
        seal_indices and seal_indices[0] != len(events) - 1
    ):
        raise OperatorEvidenceError("run_sealed must appear at most once, as the final event")
    seen_ids: set[str] = set()
    started_bout: dict[str, Any] | None = None
    last_bout: dict[str, Any] | None = None
    rest_start: float | None = None
    bouts: list[dict[str, Any]] = []
    rests: list[dict[str, float]] = []
    ratings: list[dict[str, Any]] = []
    for i, event in enumerate(events):
        kind = event["kind"]
        if kind not in MARKERS:
            continue
        if i <= start_index or (seal_indices and i >= seal_indices[0]):
            raise OperatorEvidenceError("pilot events must occur during the active run")
        payload = event.get("payload")
        if not isinstance(payload, dict):
            raise OperatorEvidenceError("pilot event requires a payload object")
        if payload.get("event_schema") != EVENT_SCHEMA:
            raise OperatorEvidenceError("wrong pilot event schema")
        event_id = _nonempty(payload.get("event_id"), "event_id")
        if event_id in seen_ids:
            raise OperatorEvidenceError("duplicate pilot event_id")
        seen_ids.add(event_id)
        time_s = (event["host_monotonic_ns"] - start_ns) / 1e9
        if time_s < 0:
            raise OperatorEvidenceError("pilot event precedes run_started")
        if kind == "indo_rest_bout_started":
            if started_bout is not None or rest_start is not None:
                raise OperatorEvidenceError("cannot start a bout while riding or resting")
            bout_id = _nonempty(payload.get("bout_id"), "bout_id")
            if any(b["bout_id"] == bout_id for b in bouts) or (
                last_bout and last_bout["bout_id"] == bout_id
            ):
                raise OperatorEvidenceError("bout_id reused")
            phase = payload.get("phase")
            if phase not in PHASES:
                raise OperatorEvidenceError("invalid bout phase")
            if phase == "post_rest" and not rests:
                raise OperatorEvidenceError("post_rest bout without a completed rest")
            context = {
                key: _nonempty(payload.get(key), key) for key in CONTEXT_KEYS
            }
            started_bout = {
                "bout_id": bout_id,
                "phase": phase,
                "start_s": time_s,
                "context": context,
            }
        elif kind == "indo_rest_bout_finished":
            bout_id = _nonempty(payload.get("bout_id"), "bout_id")
            if started_bout is None or started_bout["bout_id"] != bout_id:
                raise OperatorEvidenceError("bout end has no matching start")
            if time_s <= started_bout["start_s"]:
                raise OperatorEvidenceError("bout has nonpositive duration")
            ended = {
                **started_bout,
                "end_s": time_s,
                "effort_0_10": None,
                "metrics": {},
                "confidence": {},
                "source_verified": False,
                "source_digest_sha256": None,
            }
            bouts.append(ended)
            last_bout = ended
            started_bout = None
        elif kind == "indo_rest_rest_started":
            if started_bout is not None or rest_start is not None:
                raise OperatorEvidenceError("rest cannot overlap another bout/rest")
            rest_start = time_s
        elif kind == "indo_rest_rest_finished":
            if rest_start is None or time_s <= rest_start:
                raise OperatorEvidenceError("rest end has no valid start")
            rests.append({"start_s": rest_start, "end_s": time_s})
            rest_start = None
        elif kind == "indo_rest_effort_reported":
            bout_id = _nonempty(payload.get("bout_id"), "bout_id")
            raw_rating = payload.get("effort_0_10")
            if not isinstance(raw_rating, str) or not re.fullmatch(r"10|[0-9]", raw_rating):
                raise OperatorEvidenceError("effort must be an integer string from 0 to 10")
            if last_bout is None or last_bout["bout_id"] != bout_id:
                raise OperatorEvidenceError("effort must identify the latest finished bout")
            if started_bout is not None:
                raise OperatorEvidenceError("effort cannot be entered during a bout")
            if last_bout["effort_0_10"] is not None:
                raise OperatorEvidenceError("duplicate effort rating for bout")
            last_bout["effort_0_10"] = int(raw_rating)
            ratings.append({"bout_id": bout_id, "time_s": time_s, "effort_0_10": int(raw_rating)})

    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "source": {
            "operator_journal_sha256": actual,
            "timing_semantics": TIMING_SEMANTICS,
            "source_verified": True,
            "run_sealed": bool(seal_indices),
        },
        "bouts": bouts,
        "rests": rests,
        "ratings": ratings,
        "incomplete": {
            "bout_id": started_bout["bout_id"] if started_bout else None,
            "rest_open": rest_start is not None,
        },
        "claim_boundary": (
            "Operator annotations are not synchronized camera/Watch timestamps. "
            "Bout metrics and source_verified remain unavailable until independent "
            "video/equipment and cross-clock quality gates are passed."
        ),
    }
