"""Decode verified Watch-native Indo rest annotations without inventing clock alignment.

Require a trusted expected journal digest from the canonical phone receipt.
Watch timestamps are intentionally NOT converted into phone/camera time.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

WATCH_STREAM = "/experiments/indo/rest_annotation"
WATCH_PILOT_SCHEMA = "motionos.indo-rest-events.v1"
WATCH_CLOCK = "watch_monotonic_input_time"
WATCH_SOURCE_SCHEMA = "motionos.m0.v1"
PHASES = {"reference", "late", "post_rest"}
CONTEXT = ("skill_id", "setup_id", "stance_id", "tracking_mode")
KINDS = {
    "indo_rest_bout_started",
    "indo_rest_bout_finished",
    "indo_rest_rest_started",
    "indo_rest_rest_finished",
    "indo_rest_effort_reported",
}


class WatchRestEvidenceError(ValueError):
    """A Watch journal does not satisfy the source/annotation contract."""


def _str(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise WatchRestEvidenceError(f"{name} must be a nonempty string")
    return value


def _int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise WatchRestEvidenceError(f"{name} must be a nonnegative integer")
    return value


def extract_watch_rest_events(
    watch_journal: str | Path,
    *,
    watch_session_id: str,
    expected_sha256: str,
    expected_run_id: str | None = None,
) -> dict[str, Any]:
    """Read Watch events while preserving their independent monotonic clock.

    expected_sha256 MUST originate from a trusted, verified iPhone receipt
    (not a value claimed by the watch file itself). No camera or board metric
    becomes qualified as a result of this decoding.
    """
    watch_session_id = _str(watch_session_id, "watch_session_id")
    if expected_run_id is not None:
        _str(expected_run_id, "expected_run_id")
    if not isinstance(expected_sha256, str) or not re.fullmatch(
        r"[a-fA-F0-9]{64}", expected_sha256
    ):
        raise WatchRestEvidenceError("expected_sha256 must be a SHA-256 digest")

    data = Path(watch_journal).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_sha256.lower():
        raise WatchRestEvidenceError("Watch journal SHA-256 mismatch")

    annotations: list[dict[str, Any]] = []
    last_watch_ns: int | None = None
    for line_number, line in enumerate(data.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise WatchRestEvidenceError(f"invalid JSONL line {line_number}") from exc
        if not isinstance(event, dict):
            raise WatchRestEvidenceError(f"non-object event on line {line_number}")
        if event.get("schema_version") != WATCH_SOURCE_SCHEMA:
            raise WatchRestEvidenceError("unexpected Watch envelope schema")
        if event.get("session_id") != watch_session_id:
            raise WatchRestEvidenceError("foreign Watch session in journal")
        if event.get("stream") != WATCH_STREAM:
            continue

        if event.get("device_id") != "apple-watch":
            raise WatchRestEvidenceError("unexpected annotation device")
        seq = _int(event.get("sequence"), "sequence")
        ns = _int(event.get("device_time_ns"), "device_time_ns")
        if seq != len(annotations):
            raise WatchRestEvidenceError("annotation sequence gap or duplicate")
        if last_watch_ns is not None and ns <= last_watch_ns:
            raise WatchRestEvidenceError("non-increasing Watch event timestamp")
        last_watch_ns = ns
        payload = event.get("payload")
        if not isinstance(payload, dict):
            raise WatchRestEvidenceError("annotation payload missing")
        if payload.get("event_schema") != WATCH_PILOT_SCHEMA:
            raise WatchRestEvidenceError("annotation schema mismatch")
        if payload.get("clock_semantics") != WATCH_CLOCK:
            raise WatchRestEvidenceError("unqualified Watch time semantics")
        event_id = _str(payload.get("event_id"), "event_id")
        kind = payload.get("event_type")
        if kind not in KINDS:
            raise WatchRestEvidenceError("unknown Watch annotation")
        binding = payload.get("run_binding")
        if binding not in ("bound", "unbound"):
            raise WatchRestEvidenceError("missing run binding status")
        linked = payload.get("linked_run_id")
        if binding == "bound":
            _str(linked, "linked_run_id")
            if expected_run_id is not None and linked != expected_run_id:
                raise WatchRestEvidenceError("annotation linked to a different run")
        elif linked is not None:
            raise WatchRestEvidenceError("unbound marker contains a run identifier")
        annotations.append(
            {
                "event_id": event_id,
                "kind": kind,
                "device_time_ns": ns,
                "sequence": seq,
                "linked_run_id": linked,
                "run_binding": binding,
                "payload": payload,
            }
        )

    seen_event_ids: set[str] = set()
    seen_bout_ids: set[str] = set()
    open_bout: dict[str, Any] | None = None
    last_finished: dict[str, Any] | None = None
    open_rest: int | None = None
    bouts: list[dict[str, Any]] = []
    rests: list[dict[str, int]] = []
    ratings: list[dict[str, Any]] = []
    for event in annotations:
        event_id = event["event_id"]
        if event_id in seen_event_ids:
            raise WatchRestEvidenceError("duplicate annotation event ID")
        seen_event_ids.add(event_id)
        payload = event["payload"]
        kind = event["kind"]
        t = event["device_time_ns"]
        if kind == "indo_rest_bout_started":
            if open_bout is not None or open_rest is not None:
                raise WatchRestEvidenceError("overlapping bout/rest")
            bout_id = _str(payload.get("bout_id"), "bout_id")
            if bout_id in seen_bout_ids:
                raise WatchRestEvidenceError("duplicate bout ID")
            phase = payload.get("phase")
            if phase not in PHASES:
                raise WatchRestEvidenceError("invalid bout phase")
            if phase == "post_rest" and not rests:
                raise WatchRestEvidenceError("post-rest attempt without a completed rest")
            context = {key: _str(payload.get(key), key) for key in CONTEXT}
            seen_bout_ids.add(bout_id)
            open_bout = {
                "bout_id": bout_id,
                "phase": phase,
                "start_watch_ns": t,
                "context": context,
                "source_verified": False,
                "metrics": {},
                "confidence": {},
                "run_binding": event["run_binding"],
            }
            last_finished = None
        elif kind == "indo_rest_bout_finished":
            if open_bout is None or payload.get("bout_id") != open_bout["bout_id"]:
                raise WatchRestEvidenceError("bout end without matching start")
            finished = dict(open_bout)
            finished["end_watch_ns"] = t
            finished["effort_0_10"] = None
            bouts.append(finished)
            last_finished = finished
            open_bout = None
        elif kind == "indo_rest_rest_started":
            if open_bout is not None or open_rest is not None:
                raise WatchRestEvidenceError("rest overlaps bout/rest")
            open_rest = t
        elif kind == "indo_rest_rest_finished":
            if open_rest is None:
                raise WatchRestEvidenceError("rest end without start")
            rests.append({"start_watch_ns": open_rest, "end_watch_ns": t})
            open_rest = None
        else:
            if open_bout is not None or last_finished is None or (
                payload.get("bout_id") != last_finished["bout_id"]
            ):
                raise WatchRestEvidenceError("effort without matching finished bout")
            rating = payload.get("effort_0_10")
            if not isinstance(rating, str) or not re.fullmatch(r"[0-9]|10", rating):
                raise WatchRestEvidenceError("invalid effort rating")
            if last_finished["effort_0_10"] is not None:
                raise WatchRestEvidenceError("duplicate effort rating")
            last_finished["effort_0_10"] = int(rating)
            ratings.append(
                {"bout_id": last_finished["bout_id"], "effort_0_10": int(rating),
                 "watch_device_time_ns": t}
            )

    return {
        "schema_version": "motionos.indo-watch-rest-extract.v1",
        "watch_session_id": watch_session_id,
        "source": {
            "watch_journal_sha256": digest,
            "journal_integrity_verified": True,
            "time_domain": WATCH_CLOCK,
            "camera_alignment_verified": False,
        },
        "annotations": [
            {key: event[key] for key in
             ("event_id", "kind", "device_time_ns", "sequence",
              "run_binding", "linked_run_id")}
            for event in annotations
        ],
        "bouts": bouts,
        "rests": rests,
        "ratings": ratings,
        "incomplete": {
            "bout_id": open_bout["bout_id"] if open_bout else None,
            "rest_open": open_rest is not None,
        },
        "claim_boundary": (
            "A verified Watch journal proves what was recorded, not the "
            "alignment of Watch, iPhone camera and equipment clocks. "
            "Movement features and physiological recovery remain unqualified."
        ),
    }
