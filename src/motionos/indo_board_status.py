from __future__ import annotations

import json
from pathlib import Path

from .indo_board_pipeline import validate_indo_board_pipeline_spec
from .indo_board_plan import validate_indo_board_qualification_plan
from .provenance import sha256_file

STATUS_SCHEMA_VERSION = "motionos.indo-board-status.v1"


def build_indo_board_status(
    plan_path: str | Path,
    *,
    pipeline_spec_path: str | Path | None = None,
    results_directory: str | Path | None = None,
) -> dict[str, object]:
    plan_source = Path(plan_path).resolve()
    status: dict[str, object] = {
        "schema_version": STATUS_SCHEMA_VERSION,
        "plan": {
            "path": str(plan_source),
            "valid": False,
        },
        "pipeline_preflight": {
            "provided": pipeline_spec_path is not None,
            "valid": None,
        },
        "results": {
            "provided": results_directory is not None,
            "processed": False,
            "qualification_passed": None,
            "longitudinal_updated": None,
            "failed_gate_ids": [],
        },
    }

    try:
        plan = validate_indo_board_qualification_plan(plan_source)
    except Exception as exc:
        status["plan"] = {
            "path": str(plan_source),
            "valid": False,
            "error": str(exc),
        }
        status["next_action"] = (
            "Repair or rebuild the frozen qualification plan before "
            "capturing/scoring a session."
        )
        return status

    plan_hash = sha256_file(plan_source)
    status["plan"] = {
        "path": str(plan_source),
        "valid": True,
        "plan_id": str(plan["plan_id"]),
        "sha256": plan_hash,
        "coaching_condition":
            plan["protocol"]["coaching_condition"],
        "minimum_sync_landmarks":
            plan["protocol"]["minimum_sync_landmarks"],
    }

    if pipeline_spec_path is None:
        status["next_action"] = (
            "Capture the scored Indo Board session under this frozen plan, "
            "then create the scored pipeline spec."
        )
        return status

    pipeline_source = Path(pipeline_spec_path).resolve()
    pipeline_status: dict[str, object] = {
        "provided": True,
        "path": str(pipeline_source),
        "valid": False,
    }
    try:
        pipeline_raw = _json_object(pipeline_source)
        pipeline_plan_path = _resolve(
            pipeline_source.parent,
            pipeline_raw["qualification_plan"],
        )
        pipeline_status["qualification_plan_matches"] = (
            pipeline_plan_path.is_file()
            and sha256_file(pipeline_plan_path) == plan_hash
        )
        if not pipeline_status["qualification_plan_matches"]:
            raise ValueError(
                "pipeline spec does not reference the supplied frozen plan"
            )

        validate_indo_board_pipeline_spec(pipeline_source)
        pipeline_status["valid"] = True
        pipeline_status["sha256"] = sha256_file(pipeline_source)
    except Exception as exc:
        pipeline_status["error"] = str(exc)

    status["pipeline_preflight"] = pipeline_status
    if not bool(pipeline_status["valid"]):
        status["next_action"] = (
            "Repair scored-session preflight. Do not run reconstruction "
            "until this status is valid."
        )
        return status

    if results_directory is None:
        status["next_action"] = (
            "Run process-indo-board-vision with the validated pipeline spec."
        )
        return status

    results = Path(results_directory).resolve()
    result_status: dict[str, object] = {
        "provided": True,
        "path": str(results),
        "processed": False,
        "qualification_passed": None,
        "longitudinal_updated": None,
        "failed_gate_ids": [],
    }
    receipt_path = results / "indo-board-pipeline-receipt.json"
    quality_path = results / "indo-board-quality-report.json"
    qualification_path = (
        results / "indo-board-qualification-receipt.json"
    )

    missing = [
        path.name
        for path in (
            receipt_path,
            quality_path,
            qualification_path,
        )
        if not path.is_file()
    ]
    if missing:
        result_status["missing_artifacts"] = missing
        status["results"] = result_status
        status["next_action"] = (
            "Run or resume process-indo-board-vision; required result "
            "artifacts are still missing."
        )
        return status

    try:
        receipt = _json_object(receipt_path)
        quality = _json_object(quality_path)
        qualification = _json_object(qualification_path)
        _require_schema(
            receipt,
            "motionos.indo-board-pipeline-receipt.v1",
            label="pipeline receipt",
        )
        _require_schema(
            quality,
            "motionos.indo-board-quality-report.v1",
            label="quality report",
        )
        _require_schema(
            qualification,
            "motionos.indo-board-qualification-receipt.v1",
            label="qualification receipt",
        )
        if receipt.get("qualification_plan_sha256") != plan_hash:
            raise ValueError(
                "processed result does not reference the supplied "
                "qualification plan"
            )

        result_status.update(
            {
                "processed": True,
                "session_id": str(receipt["session_id"]),
                "qualification_passed":
                    bool(receipt["qualification_passed"]),
                "longitudinal_updated":
                    bool(receipt["longitudinal_updated"]),
                "failed_gate_ids": list(
                    receipt.get(
                        "qualification_failed_gate_ids",
                        [],
                    )
                ),
                "attention_flags": list(
                    receipt.get("attention_flags", [])
                ),
                "quality_summary":
                    receipt.get("quality_summary", {}),
                "pipeline_receipt_sha256":
                    sha256_file(receipt_path),
                "quality_report_sha256":
                    sha256_file(quality_path),
                "qualification_receipt_sha256":
                    sha256_file(qualification_path),
            }
        )
    except Exception as exc:
        result_status["error"] = str(exc)
        status["results"] = result_status
        status["next_action"] = (
            "Inspect or regenerate the result artifacts; their provenance "
            "or schema does not match this frozen experiment."
        )
        return status

    status["results"] = result_status
    if bool(result_status["qualification_passed"]):
        if bool(result_status["longitudinal_updated"]):
            status["next_action"] = (
                "Session qualified and updated the longitudinal baseline. "
                "Review metrics and quality dimensions before designing "
                "live coaching."
            )
        else:
            status["next_action"] = (
                "Session qualified. The longitudinal profile was not newly "
                "updated, likely because this session was already processed."
            )
    else:
        status["next_action"] = (
            "Session did not qualify. Inspect failed_gate_ids and the "
            "quality report; keep the evidence but do not promote it into "
            "the longitudinal model."
        )
    return status


def _resolve(base: Path, raw: object) -> Path:
    path = Path(str(raw))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw


def _require_schema(
    document: dict[str, object],
    expected: str,
    *,
    label: str,
) -> None:
    if document.get("schema_version") != expected:
        raise ValueError(f"unsupported {label} schema")
