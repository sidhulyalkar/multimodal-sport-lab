from __future__ import annotations

import json
import os
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Self

from .schema import SensorEvent, SessionManifest


def _stream_slug(stream: str) -> str:
    return stream.strip("/").replace("/", "__") or "root"


class SessionWriter:
    """Append-only session bundle writer."""

    def __init__(self, root: str | Path, manifest: SessionManifest):
        self.root = Path(root) / manifest.session_id
        self.stream_dir = self.root / "streams"
        self.meta_dir = self.root / "metadata"
        self.stream_dir.mkdir(parents=True, exist_ok=False)
        self.meta_dir.mkdir(parents=True, exist_ok=True)
        self.manifest = manifest
        self._files: dict[str, object] = {}
        self._counts: dict[str, int] = {}
        self._paths: dict[str, str] = {}
        self._closed = False
        self._write_json_atomic(self.root / "manifest.json", manifest.to_dict())

    @staticmethod
    def _write_json_atomic(path: Path, data: object) -> None:
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temp, path)

    def append(self, event: SensorEvent) -> None:
        if self._closed:
            raise RuntimeError("session writer is closed")
        if event.session_id != self.manifest.session_id:
            raise ValueError("event session_id does not match manifest")
        if event.stream not in self._files:
            rel = f"streams/{_stream_slug(event.stream)}.jsonl"
            handle = (self.root / rel).open("a", encoding="utf-8", buffering=1)
            self._files[event.stream] = handle
            self._paths[event.stream] = rel
            self._counts[event.stream] = 0
        handle = self._files[event.stream]
        handle.write(event.to_json() + "\n")
        self._counts[event.stream] += 1

    def write_metadata(self, name: str, data: object) -> Path:
        if "/" in name or "\\" in name:
            raise ValueError("metadata name must be a file stem, not a path")
        path = self.meta_dir / f"{name}.json"
        self._write_json_atomic(path, data)
        return path

    def close(self) -> Path:
        if self._closed:
            return self.root
        for handle in self._files.values():
            handle.flush()
            handle.close()
        index = {
            "schema_version": self.manifest.schema_version,
            "session_id": self.manifest.session_id,
            "streams": {
                stream: {"path": self._paths[stream], "count": self._counts[stream]}
                for stream in sorted(self._paths)
            },
        }
        self._write_json_atomic(self.root / "index.json", index)
        self._closed = True
        return self.root

    def __enter__(self) -> Self:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


class SessionReader:
    def __init__(self, session_dir: str | Path):
        self.root = Path(session_dir)
        self.manifest = SessionManifest.from_dict(
            json.loads((self.root / "manifest.json").read_text(encoding="utf-8"))
        )
        self.index = json.loads((self.root / "index.json").read_text(encoding="utf-8"))

    def list_streams(self) -> list[str]:
        return sorted(self.index["streams"])

    def iter_stream(self, stream: str) -> Iterator[SensorEvent]:
        info = self.index["streams"].get(stream)
        if info is None:
            return
        path = self.root / info["path"]
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    yield SensorEvent.from_json(line)

    def iter_events(self, streams: Iterable[str] | None = None) -> Iterator[SensorEvent]:
        selected = self.list_streams() if streams is None else list(streams)
        events: list[SensorEvent] = []
        for stream in selected:
            events.extend(self.iter_stream(stream))
        events.sort(key=lambda event: (event.canonical_time_ns, event.stream, event.sequence))
        yield from events
