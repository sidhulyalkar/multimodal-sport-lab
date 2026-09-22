from __future__ import annotations

from pathlib import Path

from .session import SessionReader


def export_mcap(session_dir: str | Path, output_path: str | Path) -> Path:
    """Export a MotionOS session bundle to MCAP."""

    try:
        from mcap.writer import Writer
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("MCAP export requires the optional 'mcap' dependency") from exc

    reader = SessionReader(session_dir)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as handle:
        writer = Writer(handle)
        writer.start()
        channels: dict[str, int] = {}
        for event in reader.iter_events():
            if event.stream not in channels:
                channels[event.stream] = writer.register_channel(
                    topic=event.stream,
                    message_encoding="json",
                )
            timestamp = event.canonical_time_ns
            writer.add_message(
                channel_id=channels[event.stream],
                log_time=timestamp,
                publish_time=timestamp,
                data=event.to_json().encode("utf-8"),
            )
        writer.finish()
    return output
