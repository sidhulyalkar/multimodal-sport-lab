from __future__ import annotations

from dataclasses import replace

from .schema import SensorEvent


def drop_sequences(events: list[SensorEvent], sequences: set[int]) -> list[SensorEvent]:
    """Remove selected sequence numbers without renumbering the stream."""
    return [event for event in events if event.sequence not in sequences]


def duplicate_sequence(events: list[SensorEvent], sequence: int) -> list[SensorEvent]:
    """Insert an exact duplicate event immediately after the target."""
    output: list[SensorEvent] = []
    for event in events:
        output.append(event)
        if event.sequence == sequence:
            output.append(event)
    return output


def reverse_timestamp_pair(events: list[SensorEvent], sequence: int) -> list[SensorEvent]:
    """Force a local timestamp reversal while preserving sequence order."""
    output = list(events)
    index = next((i for i, event in enumerate(output) if event.sequence == sequence), None)
    if index is None or index == 0:
        raise ValueError("sequence must exist and have a predecessor")
    previous = output[index - 1]
    current = output[index]
    bad_time = max(0, previous.canonical_time_ns - 1)
    output[index] = replace(current, session_time_ns=bad_time)
    return output


def degrade_sync_quality(events: list[SensorEvent], factor: float) -> list[SensorEvent]:
    """Scale synchronization quality to emulate a poorly constrained clock."""
    if not 0 <= factor <= 1:
        raise ValueError("factor must be between 0 and 1")
    return [
        replace(
            event,
            sync_quality=(
                max(0.0, min(1.0, event.sync_quality * factor))
                if event.sync_quality is not None
                else None
            ),
        )
        for event in events
    ]


def add_time_gap(
    events: list[SensorEvent], *, from_sequence: int, gap_ns: int
) -> list[SensorEvent]:
    """Shift all samples after a sequence to emulate a transport/acquisition gap."""
    if gap_ns < 0:
        raise ValueError("gap_ns must be non-negative")
    output: list[SensorEvent] = []
    for event in events:
        if event.sequence >= from_sequence:
            mapped = event.session_time_ns
            if mapped is None:
                mapped = event.device_time_ns
            output.append(replace(event, session_time_ns=mapped + gap_ns))
        else:
            output.append(event)
    return output
