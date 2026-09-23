from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

from .body_model import load_body_model_profile
from .calibration_run import build_calibration_report, load_calibration_run
from .operator_evidence import validate_operator_evidence

CLOSURE_SCHEMA_VERSION = "motionos.m0-closure.v1"
REQUIRED_SOURCE_ROLES = ("watch", "equipment", "insoles", "camera")
REQUIRED_OPERATOR_ARTIFACT_KINDS = (
    "operator_events",
    "operator_metadata",
    "operator_evidence_receipt",
)
REQUIRED_SYNC_CUES = ("start", "middle", "end")


@dataclass(frozen=True)
class M0ClosureReceipt:
    run_id: str
    passed: bool
    source_qualification: dict[str, str]
    operator_evidence: dict[str, object]
    body_model: dict[str, object]
    unresolved_blockers: tuple[str, ...]
    schema_version: str = CLOSURE_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["unresolved_blockers"] = list(self.unresolved_blockers)
        data["claim_boundary"] = (
            "A passing closure receipt means the repository can reproduce a "
            "hash-verified, physically qualified M0 multimodal run from the "
            "referenced artifacts. It does not establish biomechanical "
            "accuracy, clinical validity, or model performance."
        )
        return data


def _resolve(path: str, *, base: Path) -> Path:
    value = Path(path)
    return value if value.is_absolute() else (base / value).resolve()


def _read_json_object(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"JSON artifact must contain an object: {path}")
    return dict(raw)


def _string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if isinstance(item, str)]


def _artifact_index(run) -> dict[str, list[object]]:
    index: dict[str, list[object]] = {}
    for artifact in (*run.profiles, *run.artifacts):
        index.setdefault(artifact.kind, []).append(artifact)
    return index


def _operator_evidence_status(
    run_manifest: Path,
    run,
    artifact_index: dict[str, list[object]],
    blockers: list[str],
) -> dict[str, object]:
    summary: dict[str, object] = {
        "state": "unavailable",
        "required_artifacts": list(REQUIRED_OPERATOR_ARTIFACT_KINDS),
        "sync_cues": [],
        "completed_block_ids": [],
        "failure_notes": [],
    }

    missing = [
        kind
        for kind in REQUIRED_OPERATOR_ARTIFACT_KINDS
        if len(artifact_index.get(kind, [])) != 1
    ]
    if missing:
        blockers.append(
            "operator evidence: expected exactly one artifact for "
            + ", ".join(missing)
        )
        summary["reason"] = "missing_or_ambiguous_artifacts"
        return summary

    events_ref = artifact_index["operator_events"][0]
    receipt_ref = artifact_index["operator_evidence_receipt"][0]
    metadata_ref = artifact_index["operator_metadata"][0]
    events_path = _resolve(events_ref.path, base=run_manifest.parent)
    receipt_path = _resolve(receipt_ref.path, base=run_manifest.parent)
    metadata_path = _resolve(metadata_ref.path, base=run_manifest.parent)

    if events_path.parent != metadata_path.parent:
        blockers.append(
            "operator evidence: journal and metadata must share one directory"
        )
        summary["reason"] = "split_bundle"
        return summary

    try:
        receipt = _read_json_object(receipt_path)
        metadata = _read_json_object(metadata_path)
        recomputed = validate_operator_evidence(events_path.parent)
    except (
        OSError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as exc:
        blockers.append(
            f"operator evidence: validation failed: "
            f"{type(exc).__name__}: {exc}"
        )
        summary["reason"] = "invalid"
        return summary

    sync_labels = [
        value.lower()
        for value in recomputed.sync_cue_labels
    ]
    completed_ids = _string_list(metadata.get("completed_block_ids"))
    failure_notes = list(recomputed.failure_notes)

    summary.update(
        {
            "state": "qualified" if recomputed.passed else "failed",
            "run_id": recomputed.run_id,
            "metadata_run_id": metadata.get("run_id"),
            "protocol_version": metadata.get("protocol_version"),
            "sync_cues": sync_labels,
            "completed_block_ids": completed_ids,
            "failure_notes": failure_notes,
            "recomputed_event_count": recomputed.event_count,
        }
    )

    if not recomputed.passed:
        blockers.append("operator evidence: recomputed validation is not passing")
    if receipt.get("passed") is not recomputed.passed:
        blockers.append("operator evidence: stored receipt pass state does not recompute")
    if receipt.get("run_id") != recomputed.run_id:
        blockers.append("operator evidence: stored receipt run_id does not recompute")
    if receipt.get("source_evidence_sha256") != recomputed.source_evidence_sha256:
        blockers.append(
            "operator evidence: stored receipt source hashes do not recompute"
        )
    if recomputed.run_id != run.run_id:
        blockers.append("operator evidence: receipt run_id does not match run manifest")
    if metadata.get("run_id") != run.run_id:
        blockers.append("operator evidence: metadata run_id does not match run manifest")
    if metadata.get("protocol_version") != run.protocol_version:
        blockers.append(
            "operator evidence: metadata protocol_version does not match run manifest"
        )

    missing_sync = [
        label
        for label in REQUIRED_SYNC_CUES
        if label not in sync_labels
    ]
    if missing_sync:
        blockers.append(
            "operator evidence: missing sync cue annotations "
            + ", ".join(missing_sync)
        )

    planned_block_ids = [
        str(block["id"])
        for block in run.movement_blocks
        if isinstance(block.get("id"), str)
    ]
    missing_blocks = [
        block_id
        for block_id in planned_block_ids
        if block_id not in completed_ids
    ]
    if missing_blocks:
        blockers.append(
            "operator evidence: incomplete protocol blocks "
            + ", ".join(missing_blocks)
        )

    recorded_failures = set(run.failure_modes)
    unpropagated_failures = [
        note
        for note in failure_notes
        if note not in recorded_failures
    ]
    if unpropagated_failures:
        blockers.append(
            "operator evidence: failure notes not propagated into run.failure_modes: "
            + " | ".join(unpropagated_failures)
        )

    return summary


def _body_model_status(
    run_manifest: Path,
    run,
    artifact_index: dict[str, list[object]],
    blockers: list[str],
) -> dict[str, object]:
    refs = artifact_index.get("body_model", [])
    if not refs:
        return {
            "state": "not_requested",
            "claim_boundary": (
                "Personalized body registration is optional for M0 closure."
            ),
        }
    if len(refs) != 1:
        blockers.append("body_model: expected at most one personalized profile")
        return {"state": "invalid", "reason": "multiple_profiles"}

    ref = refs[0]
    profile_path = _resolve(ref.path, base=run_manifest.parent)
    try:
        profile = load_body_model_profile(profile_path)
    except (
        OSError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as exc:
        blockers.append(
            f"body_model: invalid personalized profile: "
            f"{type(exc).__name__}: {exc}"
        )
        return {"state": "invalid", "reason": str(exc)}

    source_hash = profile.source.artifact_sha256
    summary: dict[str, object] = {
        "state": "qualified",
        "model_id": profile.model_id,
        "profile_sha256": profile.profile_sha256,
        "source_type": profile.source.type,
        "source_artifact_sha256": source_hash,
        "registration_landmarks": list(profile.registration_landmarks),
    }

    if profile.source.type in {"example_only", "synthetic_test_profile"}:
        blockers.append(
            f"body_model: source type {profile.source.type!r} is not physical evidence"
        )
        summary["state"] = "unqualified"

    if source_hash is None:
        blockers.append(
            "body_model: physical closure requires the source artifact SHA-256"
        )
        summary["state"] = "unqualified"
    else:
        matching_refs = [
            artifact
            for artifact in (*run.profiles, *run.artifacts)
            if artifact.kind != "body_model"
            and artifact.sha256 == source_hash
        ]
        if not matching_refs:
            blockers.append(
                "body_model: source artifact hash is not referenced by the run"
            )
            summary["state"] = "unqualified"
        else:
            summary["source_artifact_kinds"] = [
                artifact.kind for artifact in matching_refs
            ]

    return summary


def evaluate_m0_closure(run_path: str | Path) -> M0ClosureReceipt:
    run_manifest = Path(run_path).resolve()
    run = load_calibration_run(run_manifest, verify_hashes=True)
    report = build_calibration_report(run_manifest)

    blockers = list(report["unresolved_blockers"])
    source_reports = {
        str(source["role"]): source
        for source in report["sources"]
        if isinstance(source, dict)
    }

    missing_roles = [
        role for role in REQUIRED_SOURCE_ROLES if role not in source_reports
    ]
    if missing_roles:
        blockers.append(
            "run: missing required source roles " + ", ".join(missing_roles)
        )

    source_qualification: dict[str, str] = {}
    for role in REQUIRED_SOURCE_ROLES:
        source = source_reports.get(role)
        if source is None:
            source_qualification[role] = "missing"
            continue
        qualification = source.get("qualification")
        state = (
            str(qualification.get("state"))
            if isinstance(qualification, dict)
            else "missing"
        )
        source_qualification[role] = state
        if state != "qualified":
            message = (
                f"{role}: full physical qualification required "
                f"(current state: {state})"
            )
            if message not in blockers:
                blockers.append(message)

    artifact_index = _artifact_index(run)
    operator_status = _operator_evidence_status(
        run_manifest,
        run,
        artifact_index,
        blockers,
    )
    body_status = _body_model_status(
        run_manifest,
        run,
        artifact_index,
        blockers,
    )

    blockers = list(dict.fromkeys(blockers))
    return M0ClosureReceipt(
        run_id=run.run_id,
        passed=not blockers,
        source_qualification=source_qualification,
        operator_evidence=operator_status,
        body_model=body_status,
        unresolved_blockers=tuple(blockers),
    )


def write_m0_closure_receipt(
    run_path: str | Path,
    output_path: str | Path,
) -> M0ClosureReceipt:
    receipt = evaluate_m0_closure(run_path)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m motionos.closure",
        description="Validate final MotionOS M0 physical-run closure evidence.",
    )
    parser.add_argument("run")
    parser.add_argument("--receipt", default="m0-closure-receipt.json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    receipt = write_m0_closure_receipt(args.run, args.receipt)
    print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
    return 0 if receipt.passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
