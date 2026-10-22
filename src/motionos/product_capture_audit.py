"""Read-only integrity audit for exported iOS MotionOS product sessions.

The report is about file availability and hash linkage, not calibrated
biomechanics, physical synchronization, or Watch hardware qualification.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

from .provenance import sha256_file

REPORT_VERSION = "motionos.product-capture-audit.v1"
MANIFEST_VERSION = "motionos.product-session.v1"
_SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,160}$")


def _json(path: Path) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"not a JSON object: {path}")
    return raw


def _identifier(raw: object, name: str) -> str:
    if not isinstance(raw, str) or not _SAFE_ID.fullmatch(raw):
        raise ValueError(f"{name} must be a safe MotionOS session identifier")
    return raw


def _source(
    path: Path,
    *,
    label: str,
    expected: object = None,
    required: bool = True,
    expected_bytes: object = None,
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "role": label,
        "present": path.is_file(),
        "hash_matches": None,
        "bytes_match": None,
        "path": str(path.resolve()),
    }
    if not path.is_file():
        entry["status"] = "missing" if required else "optional_missing"
        return entry
    entry["bytes"] = path.stat().st_size
    if path.stat().st_size == 0:
        entry["status"] = "empty"
        return entry
    if expected_bytes is not None:
        entry["bytes_match"] = (
            type(expected_bytes) is int and entry["bytes"] == expected_bytes
        )
    digest = sha256_file(path)
    entry["sha256"] = digest
    if expected is not None:
        entry["hash_matches"] = (
            isinstance(expected, str) and digest == expected.lower()
        )
        entry["status"] = "verified" if entry["hash_matches"] else "hash_mismatch"
    else:
        entry["status"] = "present_unbound"
    if entry["bytes_match"] is False:
        entry["status"] = "byte_count_mismatch"
    return entry


def _valid_jsonl(path: Path, *, run_id: str | None = None) -> dict[str, Any]:
    """Structural continuity, never a substitute for full stream validation."""
    if not path.is_file():
        return {"valid": False, "reason": "missing"}
    count = 0
    previous_by_stream: dict[str, int] = {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                if not isinstance(row, dict):
                    return {"valid": False, "reason": "non_object_event"}
                if run_id is not None and row.get("run_id") != run_id:
                    return {"valid": False, "reason": "run_id_mismatch"}
                seq = row.get("sequence")
                if type(seq) is int:
                    stream = row.get("stream", "__single_journal__")
                    if not isinstance(stream, str):
                        return {"valid": False, "reason": "invalid_stream"}
                    previous = previous_by_stream.get(stream)
                    if previous is not None and seq <= previous:
                        return {"valid": False, "reason": "sequence_not_increasing"}
                    previous_by_stream[stream] = seq
                count += 1
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {"valid": False, "reason": "invalid_jsonl"}
    return {"valid": count > 0, "event_count": count}


def build_product_capture_audit(
    run_directory: str | Path,
    *,
    documents_directory: str | Path | None = None,
) -> dict[str, Any]:
    run = Path(run_directory).resolve()
    if not run.is_dir():
        raise FileNotFoundError(f"MotionOS run directory not found: {run}")
    if run.parent.name != "MotionOSRuns":
        raise ValueError("expected iPhone Documents/MotionOSRuns/<run-id> directory")
    docs = (
        Path(documents_directory).resolve()
        if documents_directory is not None else run.parent.parent
    )
    manifest_path = run / "product-session.json"
    if not manifest_path.is_file():
        raise FileNotFoundError("product-session.json is missing from the run")
    manifest = _json(manifest_path)
    if manifest.get("schemaVersion") != MANIFEST_VERSION:
        raise ValueError("unknown product manifest schema")
    run_id = _identifier(manifest.get("runID"), "runID")
    if run.name != run_id:
        raise ValueError("run directory does not match product manifest runID")
    if manifest.get("sport") != "indo_board":
        raise ValueError("this audit currently supports Indo Board product sessions")

    outcomes = {"completed", "aborted"}
    outcome = manifest.get("outcome")
    if outcome not in outcomes:
        raise ValueError(f"unknown product run outcome: {outcome}")

    items: list[dict[str, Any]] = []
    items.append(_source(
        run / "operator-events.jsonl",
        label="operator_journal",
        expected=manifest.get("operatorJournalSHA256"),
    ))
    items.append(_source(
        run / "operator-metadata.json",
        label="operator_metadata",
        expected=manifest.get("operatorMetadataSHA256"),
    ))
    op_meta_path = run / "operator-metadata.json"
    metadata = _json(op_meta_path) if op_meta_path.is_file() else {}
    issues: list[str] = []
    warnings: list[str] = []
    if metadata and metadata.get("run_id") != run_id:
        issues.append("operator_metadata_run_id_mismatch")
    if not manifest.get("operatorEvidenceSealed"):
        warnings.append("operator_not_sealed")

    watch_id = manifest.get("watchSessionID")
    if isinstance(watch_id, str) and watch_id:
        wid = _identifier(watch_id, "watchSessionID")
        watch_path = docs / "MotionOSInbox" / wid / "watch.jsonl"
        items.append(_source(
            watch_path,
            label="watch_journal",
            expected=manifest.get("watchJournalSHA256"),
            expected_bytes=manifest.get("watchJournalByteCount"),
        ))
        if watch_path.is_file():
            watch_jsonl = _valid_jsonl(watch_path)
            if not watch_jsonl["valid"]:
                issues.append("watch_journal_invalid_jsonl")
    else:
        warnings.append("watch_session_id_pending")

    camera_id = manifest.get("cameraSessionID")
    if isinstance(camera_id, str) and camera_id:
        cid = _identifier(camera_id, "cameraSessionID")
        camera_root = docs / "MotionOSCamera" / cid
        items.extend([
            _source(
                camera_root / "camera.mov",
                label="camera_video",
                expected=manifest.get("cameraVideoSHA256"),
            ),
            _source(
                camera_root / "camera-frames.jsonl",
                label="camera_journal",
                expected=manifest.get("cameraJournalSHA256"),
            ),
            _source(
                camera_root / "camera-metadata.json",
                label="camera_metadata",
                expected=manifest.get("cameraMetadataSHA256"),
            ),
        ])
        if (camera_root / "camera-frames.jsonl").is_file():
            camera_events = _valid_jsonl(camera_root / "camera-frames.jsonl")
            if not camera_events["valid"]:
                issues.append("camera_journal_invalid_jsonl")
    else:
        issues.append("camera_session_id_missing")

    if not manifest.get("cameraEvidenceSealed"):
        warnings.append("camera_not_sealed")
    if (run / "operator-events.jsonl").is_file():
        operator_events = _valid_jsonl(
            run / "operator-events.jsonl",
            run_id=run_id,
        )
        if not operator_events["valid"]:
            issues.append("operator_journal_invalid_jsonl")

    cues = manifest.get("syncReceipts")
    if not isinstance(cues, list):
        raise TypeError("syncReceipts must be an array")
    labels = [
        x.get("label") for x in cues if isinstance(x, dict)
    ]
    missing_cues = [
        name for name in ("start", "middle", "end") if name not in labels
    ]
    if missing_cues:
        warnings.append("missing_sync_cues:" + ",".join(missing_cues))
    if len(labels) != len(set(labels)):
        issues.append("duplicate_sync_labels")

    # Action 4 is not assumed to have been automatically started or imported.
    if manifest.get("externalCameraExpected") is True:
        if manifest.get("externalCameraImported") is True:
            source = run / "external" / "action4"
            videos = sorted(
                p for p in source.glob("*") if p.is_file()
                and p.suffix.lower() in {".mp4", ".mov"}
            )
            if len(videos) != 1:
                issues.append("external_video_count_invalid")
            else:
                items.append(_source(
                    videos[0],
                    label="external_video",
                    expected=manifest.get("externalCameraSHA256"),
                ))
        else:
            warnings.append("external_camera_import_pending")

    for item in items:
        if item["status"] in {"empty", "hash_mismatch", "byte_count_mismatch"}:
            issues.append(item["role"] + ":" + item["status"])
        elif item["status"] == "missing":
            warnings.append(item["role"] + "_missing_or_not_exported")
        elif item["status"] == "present_unbound":
            warnings.append(item["role"] + "_without_manifest_digest")
    if outcome == "aborted":
        warnings.append("session_aborted")

    # Even all matching file hashes cannot prove cross-device clocks or
    # physical Watch/video continuity.
    status = (
        "integrity_problem" if issues else
        "incomplete_evidence" if warnings else "export_hashes_verified"
    )
    return {
        "schema_version": REPORT_VERSION,
        "run_id": run_id,
        "outcome": outcome,
        "capture_mode": manifest.get("captureMode"),
        "status": status,
        "artifacts": items,
        "sync_labels": labels,
        "missing_sync_labels": missing_cues,
        "issues": sorted(set(issues)),
        "warnings": sorted(set(warnings)),
        "physical_capture_qualified": False,
        "biomechanics_validated": False,
        "claim_boundary": (
            "This report audits exported file presence and hash linkage only. "
            "Missing sibling directories may mean an incomplete export, not data loss. "
            "Matching hashes do not prove camera-to-Watch timing, signal quality, "
            "actual biomechanics, or physiological ground truth."
        ),
    }


def write_product_capture_audit(
    run_directory: str | Path,
    output_path: str | Path,
    *,
    documents_directory: str | Path | None = None,
) -> dict[str, Any]:
    report = build_product_capture_audit(
        run_directory, documents_directory=documents_directory
    )
    output = Path(output_path).resolve()
    run = Path(run_directory).resolve()
    if output.is_relative_to(run) or output.is_relative_to(run.parent.parent):
        raise ValueError("audit output must be outside the exported evidence directory")
    if output.exists():
        raise FileExistsError("refusing to overwrite an existing audit or source artifact")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, output)
    return report
