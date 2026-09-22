from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

from .provenance import sha256_file

OPERATOR_EVENT_SCHEMA = "motionos.operator-events.v1"
OPERATOR_METADATA_SCHEMA = "motionos.operator-metadata.v1"
OPERATOR_TIMING_SEMANTICS = "annotation_only_not_sync_authority"


@dataclass(frozen=True)
class OperatorEvidenceReceipt:
    run_id: str
    passed: bool
    event_count: int
    first_host_monotonic_ns: int | None
    last_host_monotonic_ns: int | None
    non_monotonic_events: int
    missing_sequence_events: int
    schema_errors: int
    run_id_errors: int
    timing_semantics_errors: int
    metadata_errors: tuple[str, ...]
    sync_cue_labels: tuple[str, ...]
    failure_notes: tuple[str, ...]
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["metadata_errors"] = list(self.metadata_errors)
        data["sync_cue_labels"] = list(self.sync_cue_labels)
        data["failure_notes"] = list(self.failure_notes)
        data["claim_boundary"] = (
            "Operator timestamps document protocol intent and observed failures "
            "only. They are not cross-device synchronization authority."
        )
        return data


def _load_metadata(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("operator metadata must be a JSON object")
    return dict(raw)


def _load_events(path: Path) -> list[dict[str, object]]:
    events: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"invalid operator JSON at {path}:{line_number}"
                ) from exc
            if not isinstance(raw, dict):
                raise TypeError(
                    f"operator event at {path}:{line_number} must be an object"
                )
            events.append(dict(raw))
    if not events:
        raise ValueError("operator journal contains no events")
    return events


def validate_operator_evidence(
    directory: str | Path,
) -> OperatorEvidenceReceipt:
    root = Path(directory)
    journal = root / "operator-events.jsonl"
    metadata_path = root / "operator-metadata.json"
    if not journal.is_file():
        raise FileNotFoundError(f"operator journal missing: {journal}")
    if not metadata_path.is_file():
        raise FileNotFoundError(
            f"operator metadata missing: {metadata_path}"
        )

    metadata = _load_metadata(metadata_path)
    events = _load_events(journal)

    metadata_errors: set[str] = set()
    if metadata.get("schema_version") != OPERATOR_METADATA_SCHEMA:
        metadata_errors.add("metadata.schema_version")
    if metadata.get("event_schema_version") != OPERATOR_EVENT_SCHEMA:
        metadata_errors.add("metadata.event_schema_version")
    if metadata.get("timing_semantics") != OPERATOR_TIMING_SEMANTICS:
        metadata_errors.add("metadata.timing_semantics")

    run_id = str(metadata.get("run_id", ""))
    if not run_id:
        metadata_errors.add("metadata.run_id")

    try:
        metadata_event_count = int(metadata.get("event_count", -1))
    except (TypeError, ValueError):
        metadata_event_count = -1
    if metadata_event_count != len(events):
        metadata_errors.add("metadata.event_count")

    expected_journal_hash = metadata.get("operator_events_sha256")
    actual_journal_hash = sha256_file(journal)
    if expected_journal_hash != actual_journal_hash:
        metadata_errors.add("metadata.operator_events_sha256")

    non_monotonic = 0
    missing_sequences = 0
    schema_errors = 0
    run_id_errors = 0
    timing_errors = 0
    previous_time: int | None = None
    expected_sequence = 0
    first_time: int | None = None
    last_time: int | None = None
    sync_labels: list[str] = []
    failure_notes: list[str] = []

    for event in events:
        if event.get("schema_version") != OPERATOR_EVENT_SCHEMA:
            schema_errors += 1
        if event.get("run_id") != run_id:
            run_id_errors += 1
        if event.get("timing_semantics") != OPERATOR_TIMING_SEMANTICS:
            timing_errors += 1

        try:
            sequence = int(event["sequence"])
            host_time = int(event["host_monotonic_ns"])
        except (KeyError, TypeError, ValueError):
            schema_errors += 1
            continue

        if sequence != expected_sequence:
            missing_sequences += abs(sequence - expected_sequence)
            expected_sequence = sequence
        expected_sequence += 1

        if previous_time is not None and host_time < previous_time:
            non_monotonic += 1
        previous_time = host_time
        first_time = host_time if first_time is None else first_time
        last_time = host_time

        if event.get("kind") == "sync_cue_annotation":
            label = event.get("label")
            if isinstance(label, str):
                sync_labels.append(label)

        if event.get("kind") == "failure_note":
            payload = event.get("payload")
            if isinstance(payload, dict):
                message = payload.get("message")
                if isinstance(message, str):
                    failure_notes.append(message)

    passed = (
        not metadata_errors
        and non_monotonic == 0
        and missing_sequences == 0
        and schema_errors == 0
        and run_id_errors == 0
        and timing_errors == 0
    )

    return OperatorEvidenceReceipt(
        run_id=run_id,
        passed=passed,
        event_count=len(events),
        first_host_monotonic_ns=first_time,
        last_host_monotonic_ns=last_time,
        non_monotonic_events=non_monotonic,
        missing_sequence_events=missing_sequences,
        schema_errors=schema_errors,
        run_id_errors=run_id_errors,
        timing_semantics_errors=timing_errors,
        metadata_errors=tuple(sorted(metadata_errors)),
        sync_cue_labels=tuple(sync_labels),
        failure_notes=tuple(failure_notes),
        source_evidence_sha256={
            "operator_events_jsonl": actual_journal_hash,
            "operator_metadata_json": sha256_file(metadata_path),
        },
    )


def write_operator_evidence_receipt(
    directory: str | Path,
    output_path: str | Path,
) -> OperatorEvidenceReceipt:
    receipt = validate_operator_evidence(directory)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
