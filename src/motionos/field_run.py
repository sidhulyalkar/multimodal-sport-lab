from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from itertools import pairwise
from pathlib import Path

from .provenance import sha256_file

FIELD_RUN_SCHEMA_VERSION = "motionos.field-run.v1"
FIELD_RUN_TIMING_AUTHORITY = "operator_annotation_only"


@dataclass(frozen=True)
class FieldRunOperatorEvent:
    run_id: str
    sequence: int
    event_type: str
    host_monotonic_ns: int
    wall_time_utc: str
    label: str | None
    block_id: str | None
    state: dict[str, str]
    timing_authority: str
    schema_version: str

    @classmethod
    def from_dict(
        cls,
        data: dict[str, object],
    ) -> FieldRunOperatorEvent:
        state_raw = data.get("state")
        if not isinstance(state_raw, dict):
            raise TypeError("field-run event state must be an object")
        state = {
            str(key): str(value)
            for key, value in state_raw.items()
        }
        return cls(
            run_id=str(data["run_id"]),
            sequence=int(data["sequence"]),
            event_type=str(data["event_type"]),
            host_monotonic_ns=int(data["host_monotonic_ns"]),
            wall_time_utc=str(data["wall_time_utc"]),
            label=(
                str(data["label"])
                if data.get("label") is not None
                else None
            ),
            block_id=(
                str(data["block_id"])
                if data.get("block_id") is not None
                else None
            ),
            state=state,
            timing_authority=str(data["timing_authority"]),
            schema_version=str(data["schema_version"]),
        )


@dataclass(frozen=True)
class FieldRunReceipt:
    run_id: str
    integrity_passed: bool
    protocol_complete: bool
    clean_run: bool
    event_count: int
    sequence_errors: int
    non_monotonic_host_times: int
    invalid_wall_times: int
    invalid_events: int
    metadata_mismatches: tuple[str, ...]
    sync_markers: tuple[str, ...]
    planned_blocks: tuple[str, ...]
    completed_blocks: tuple[str, ...]
    incomplete_blocks: tuple[str, ...]
    operator_notes: tuple[str, ...]
    failure_markers: tuple[str, ...]
    state_snapshots: tuple[dict[str, str], ...]
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def _paths(
    path: str | Path,
) -> tuple[Path, Path, Path]:
    source = Path(path)
    directory = source if source.is_dir() else source.parent
    return (
        directory,
        directory / "field-run.jsonl",
        directory / "field-run-metadata.json",
    )


def _parse_wall_time(value: str) -> bool:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def load_field_run_events(
    path: str | Path,
) -> tuple[FieldRunOperatorEvent, ...]:
    _, ledger, _ = _paths(path)
    if not ledger.is_file():
        raise FileNotFoundError(f"field-run ledger is missing: {ledger}")

    events: list[FieldRunOperatorEvent] = []
    with ledger.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
                if not isinstance(raw, dict):
                    raise TypeError("event must be an object")
                events.append(FieldRunOperatorEvent.from_dict(raw))
            except Exception as exc:
                raise ValueError(
                    f"invalid field-run event at {ledger}:{line_number}"
                ) from exc

    if not events:
        raise ValueError("field-run ledger contains no events")
    return tuple(events)


def _metadata(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("field-run metadata must contain an object")
    return dict(raw)


def build_field_run_receipt(
    path: str | Path,
) -> FieldRunReceipt:
    _, ledger, metadata_path = _paths(path)
    if not metadata_path.is_file():
        raise FileNotFoundError(
            f"field-run metadata is missing: {metadata_path}"
        )

    events = load_field_run_events(ledger)
    metadata = _metadata(metadata_path)

    run_ids = {event.run_id for event in events}
    run_id = next(iter(run_ids)) if len(run_ids) == 1 else ""
    expected_sequences = list(range(len(events)))
    actual_sequences = [event.sequence for event in events]
    sequence_errors = sum(
        actual != expected
        for actual, expected in zip(
            actual_sequences,
            expected_sequences,
            strict=True,
        )
    )
    non_monotonic = sum(
        current.host_monotonic_ns <= previous.host_monotonic_ns
        for previous, current in pairwise(events)
    )
    invalid_wall_times = sum(
        not _parse_wall_time(event.wall_time_utc)
        for event in events
    )

    required_state_keys = {
        "watch",
        "equipment_pod",
        "camera",
        "insoles",
    }
    allowed_event_types = {
        "run_started",
        "run_stopped",
        "sync_marker",
        "movement_block_started",
        "movement_block_completed",
        "operator_note",
        "failure_marker",
    }
    invalid_events = sum(
        event.schema_version != FIELD_RUN_SCHEMA_VERSION
        or event.timing_authority != FIELD_RUN_TIMING_AUTHORITY
        or event.host_monotonic_ns < 0
        or event.event_type not in allowed_event_types
        or set(event.state) != required_state_keys
        for event in events
    )

    event_counts: dict[str, int] = {}
    for event in events:
        event_counts[event.event_type] = (
            event_counts.get(event.event_type, 0) + 1
        )

    planned_raw = metadata.get("planned_movement_blocks")
    planned = (
        tuple(str(value) for value in planned_raw)
        if isinstance(planned_raw, list)
        else ()
    )
    completed = tuple(
        dict.fromkeys(
            event.block_id
            for event in events
            if event.event_type == "movement_block_completed"
            and event.block_id is not None
        )
    )
    incomplete = tuple(
        block
        for block in planned
        if block not in completed
    )
    sync_markers = tuple(
        dict.fromkeys(
            event.label
            for event in events
            if event.event_type == "sync_marker"
            and event.label is not None
        )
    )
    operator_notes = tuple(
        event.label
        for event in events
        if event.event_type == "operator_note"
        and event.label is not None
    )
    failure_markers = tuple(
        event.label
        for event in events
        if event.event_type == "failure_marker"
        and event.label is not None
    )

    metadata_counts_raw = metadata.get("event_counts")
    metadata_counts = (
        {
            str(key): int(value)
            for key, value in metadata_counts_raw.items()
        }
        if isinstance(metadata_counts_raw, dict)
        else {}
    )

    mismatches: set[str] = set()
    expected_metadata: dict[str, object] = {
        "schema_version": FIELD_RUN_SCHEMA_VERSION,
        "run_id": run_id,
        "timing_authority": FIELD_RUN_TIMING_AUTHORITY,
        "ledger_sha256": sha256_file(ledger),
    }
    for key, expected in expected_metadata.items():
        if metadata.get(key) != expected:
            mismatches.add(key)
    if metadata_counts != event_counts:
        mismatches.add("event_counts")
    if not planned:
        mismatches.add("planned_movement_blocks")
    if len(run_ids) != 1:
        mismatches.add("run_id_consistency")

    run_started = event_counts.get("run_started", 0) == 1
    run_stopped = event_counts.get("run_stopped", 0) == 1
    required_sync = {"start", "middle", "end"}
    protocol_complete = (
        run_started
        and run_stopped
        and required_sync.issubset(sync_markers)
        and not incomplete
    )
    integrity_passed = (
        sequence_errors == 0
        and non_monotonic == 0
        and invalid_wall_times == 0
        and invalid_events == 0
        and not mismatches
    )

    return FieldRunReceipt(
        run_id=run_id,
        integrity_passed=integrity_passed,
        protocol_complete=protocol_complete,
        clean_run=(
            integrity_passed
            and protocol_complete
            and not failure_markers
        ),
        event_count=len(events),
        sequence_errors=sequence_errors,
        non_monotonic_host_times=non_monotonic,
        invalid_wall_times=invalid_wall_times,
        invalid_events=invalid_events,
        metadata_mismatches=tuple(sorted(mismatches)),
        sync_markers=sync_markers,
        planned_blocks=planned,
        completed_blocks=completed,
        incomplete_blocks=incomplete,
        operator_notes=operator_notes,
        failure_markers=failure_markers,
        state_snapshots=tuple(dict(event.state) for event in events),
        source_evidence_sha256={
            "field_run_jsonl": sha256_file(ledger),
            "field_run_metadata_json": sha256_file(metadata_path),
        },
    )


def write_field_run_receipt(
    path: str | Path,
    output_path: str | Path,
) -> FieldRunReceipt:
    receipt = build_field_run_receipt(path)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
