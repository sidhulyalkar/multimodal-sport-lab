from __future__ import annotations

import hashlib
import json
import math
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path

from .clock import ClockModel, ClockObservation, estimate_clock_model
from .provenance import (
    session_evidence_sha256,
    source_evidence_hashes,
)
from .schema import SensorEvent
from .session import SessionReader

CLOCK_SYNC_SCHEMA_VERSION = "motionos.clock-sync.v1"


@dataclass(frozen=True)
class ClockLandmark:
    index: int
    reference_window_start_ns: int
    reference_window_end_ns: int
    target_window_start_ns: int
    target_window_end_ns: int
    reference_time_ns: int
    target_device_time_ns: int
    uncertainty_ns: int
    reference_sequence: int
    target_sequence: int
    reference_peak_value: float
    target_peak_value: float

    def to_dict(self) -> dict[str, object]:
        return asdict(self)

    def to_observation(self) -> ClockObservation:
        return ClockObservation(
            device_time_ns=self.target_device_time_ns,
            session_time_ns=self.reference_time_ns,
            round_trip_ns=self.uncertainty_ns,
        )


@dataclass(frozen=True)
class LandmarkCoverage:
    passed: bool
    observation_count: int
    target_capture_start_ns: int
    target_capture_end_ns: int
    observation_span_ns: int
    observation_span_fraction: float
    first_position_fraction: float
    last_position_fraction: float
    has_middle_landmark: bool

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class SessionClockIdentity:
    session_id: str
    stream: str
    bundle_sha256: str
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return {
            "session_id": self.session_id,
            "stream": self.stream,
            "bundle_sha256": self.bundle_sha256,
            "source_evidence_sha256": dict(self.source_evidence_sha256),
        }


@dataclass(frozen=True)
class ClockSyncReceipt:
    reference: SessionClockIdentity
    target: SessionClockIdentity
    landmarks: tuple[ClockLandmark, ...]
    coverage: LandmarkCoverage
    clock_model: ClockModel
    windows_sha256: str
    reference_peak_keys: tuple[str, ...]
    target_peak_keys: tuple[str, ...]
    schema_version: str = CLOCK_SYNC_SCHEMA_VERSION

    @property
    def observations(self) -> tuple[ClockObservation, ...]:
        return tuple(landmark.to_observation() for landmark in self.landmarks)

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "reference": self.reference.to_dict(),
            "target": self.target.to_dict(),
            "windows_sha256": self.windows_sha256,
            "peak_metric": {
                "type": "euclidean_magnitude",
                "reference_keys": list(self.reference_peak_keys),
                "target_keys": list(self.target_peak_keys),
            },
            "landmarks": [landmark.to_dict() for landmark in self.landmarks],
            "observations": [
                {
                    "device_time_ns": observation.device_time_ns,
                    "session_time_ns": observation.session_time_ns,
                    "round_trip_ns": observation.round_trip_ns,
                }
                for observation in self.observations
            ],
            "coverage": self.coverage.to_dict(),
            "clock_model": {
                "slope": self.clock_model.slope,
                "intercept_ns": self.clock_model.intercept_ns,
                "drift_ppm": self.clock_model.drift_ppm,
                "residual_rms_ns": self.clock_model.residual_rms_ns,
                "residual_rms_ms": self.clock_model.residual_rms_ns / 1e6,
                "observations_used": self.clock_model.observations_used,
                "quality": self.clock_model.quality,
            },
            "mapping": (
                "target.device_time_ns -> reference canonical/session time"
            ),
            "claim_boundary": (
                "This receipt records deliberate landmark correspondences and "
                "an affine temporal mapping. It does not validate physical "
                "sensor accuracy or biomechanical interpretation."
            ),
        }


def _json_sha256(value: object) -> str:
    raw = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _numeric_magnitude(
    event: SensorEvent,
    keys: tuple[str, ...],
) -> float:
    if not keys:
        raise ValueError("peak metric requires at least one payload key")
    values: list[float] = []
    for key in keys:
        try:
            value = float(event.payload[key])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"event {event.stream} lacks numeric peak channel {key!r}"
            ) from exc
        if not math.isfinite(value):
            raise ValueError(
                f"event {event.stream} peak channel {key!r} is not finite"
            )
        values.append(value)
    return math.sqrt(sum(value * value for value in values))


def _event_axis_time(
    event: SensorEvent,
    *,
    axis: str,
) -> int:
    if axis == "reference":
        return event.canonical_time_ns
    if axis == "target":
        return event.device_time_ns
    raise ValueError(f"unknown clock search axis: {axis}")


def _peak_in_window(
    events: list[SensorEvent],
    start_ns: int,
    end_ns: int,
    *,
    axis: str,
    keys: tuple[str, ...],
) -> tuple[SensorEvent, float]:
    if end_ns <= start_ns:
        raise ValueError("synchronization window end must be after start")
    candidates = [
        event
        for event in events
        if start_ns
        <= _event_axis_time(event, axis=axis)
        <= end_ns
    ]
    if not candidates:
        raise ValueError(
            f"no events inside {axis} synchronization window "
            f"{start_ns}:{end_ns}"
        )

    scored = [
        (_numeric_magnitude(event, keys), event)
        for event in candidates
    ]
    peak_value, peak = max(scored, key=lambda item: item[0])
    return peak, peak_value


def _target_bounds(events: list[SensorEvent]) -> tuple[int, int]:
    if len(events) < 2:
        raise ValueError("target synchronization stream requires >=2 events")
    times = sorted(event.device_time_ns for event in events)
    if times[-1] <= times[0]:
        raise ValueError("target synchronization stream must span time")
    return times[0], times[-1]


def landmark_coverage(
    observations: Iterable[ClockObservation],
    target_events: list[SensorEvent],
) -> LandmarkCoverage:
    items = sorted(
        observations,
        key=lambda item: item.device_time_ns,
    )
    if len(items) < 3:
        raise ValueError("at least three synchronization landmarks are required")

    target_start, target_end = _target_bounds(target_events)
    span = target_end - target_start

    normalized = [
        (item.device_time_ns - target_start) / span
        for item in items
    ]
    positions_in_range = all(0.0 <= value <= 1.0 for value in normalized)
    has_middle = any(0.30 <= value <= 0.70 for value in normalized[1:-1])
    observation_span = items[-1].device_time_ns - items[0].device_time_ns

    passed = (
        positions_in_range
        and normalized[0] <= 0.20
        and has_middle
        and normalized[-1] >= 0.80
    )

    return LandmarkCoverage(
        passed=passed,
        observation_count=len(items),
        target_capture_start_ns=target_start,
        target_capture_end_ns=target_end,
        observation_span_ns=observation_span,
        observation_span_fraction=observation_span / span,
        first_position_fraction=normalized[0],
        last_position_fraction=normalized[-1],
        has_middle_landmark=has_middle,
    )


def _window_value(
    window: dict[str, object],
    *,
    generic_key: str,
    legacy_key: str | None = None,
) -> int:
    value = window.get(generic_key)
    if value is None and legacy_key is not None:
        value = window.get(legacy_key)
    if value is None:
        raise KeyError(generic_key)
    return int(value)


def derive_clock_sync(
    reference_reader: SessionReader,
    target_reader: SessionReader,
    windows: list[dict[str, object]],
    *,
    reference_stream: str,
    target_stream: str,
    reference_peak_keys: tuple[str, ...] = ("ax", "ay", "az"),
    target_peak_keys: tuple[str, ...] = ("ax", "ay", "az"),
    allow_legacy_pod_windows: bool = False,
) -> ClockSyncReceipt:
    """Fit a target-device clock to a reference session from explicit landmarks.

    No global unconstrained peak matching is performed. Every correspondence is
    selected only inside a user-declared reference window and target window.
    """

    reference_events = list(reference_reader.iter_stream(reference_stream))
    target_events = list(target_reader.iter_stream(target_stream))
    if not reference_events:
        raise ValueError(f"reference stream is empty: {reference_stream}")
    if not target_events:
        raise ValueError(f"target stream is empty: {target_stream}")
    if len(windows) < 3:
        raise ValueError("at least three synchronization windows are required")

    landmarks: list[ClockLandmark] = []
    for index, window in enumerate(windows):
        try:
            reference_start = _window_value(
                window,
                generic_key="reference_start_ns",
            )
            reference_end = _window_value(
                window,
                generic_key="reference_end_ns",
            )
            target_start = _window_value(
                window,
                generic_key="target_start_ns",
                legacy_key=(
                    "pod_start_ns"
                    if allow_legacy_pod_windows
                    else None
                ),
            )
            target_end = _window_value(
                window,
                generic_key="target_end_ns",
                legacy_key=(
                    "pod_end_ns"
                    if allow_legacy_pod_windows
                    else None
                ),
            )
            uncertainty_ns = max(
                0,
                int(window.get("uncertainty_ns", 0)),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"invalid synchronization window at index {index}"
            ) from exc

        reference_peak, reference_value = _peak_in_window(
            reference_events,
            reference_start,
            reference_end,
            axis="reference",
            keys=reference_peak_keys,
        )
        target_peak, target_value = _peak_in_window(
            target_events,
            target_start,
            target_end,
            axis="target",
            keys=target_peak_keys,
        )

        landmarks.append(
            ClockLandmark(
                index=index,
                reference_window_start_ns=reference_start,
                reference_window_end_ns=reference_end,
                target_window_start_ns=target_start,
                target_window_end_ns=target_end,
                reference_time_ns=reference_peak.canonical_time_ns,
                target_device_time_ns=target_peak.device_time_ns,
                uncertainty_ns=uncertainty_ns,
                reference_sequence=reference_peak.sequence,
                target_sequence=target_peak.sequence,
                reference_peak_value=reference_value,
                target_peak_value=target_value,
            )
        )

    observations = [landmark.to_observation() for landmark in landmarks]
    coverage = landmark_coverage(observations, target_events)
    model = estimate_clock_model(
        observations,
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )

    return ClockSyncReceipt(
        reference=SessionClockIdentity(
            session_id=reference_reader.manifest.session_id,
            stream=reference_stream,
            bundle_sha256=session_evidence_sha256(reference_reader),
            source_evidence_sha256=source_evidence_hashes(reference_reader),
        ),
        target=SessionClockIdentity(
            session_id=target_reader.manifest.session_id,
            stream=target_stream,
            bundle_sha256=session_evidence_sha256(target_reader),
            source_evidence_sha256=source_evidence_hashes(target_reader),
        ),
        landmarks=tuple(landmarks),
        coverage=coverage,
        clock_model=model,
        windows_sha256=_json_sha256(windows),
        reference_peak_keys=reference_peak_keys,
        target_peak_keys=target_peak_keys,
    )


def validate_clock_sync_receipt(
    receipt: ClockSyncReceipt,
    reference_reader: SessionReader,
    target_reader: SessionReader,
) -> ClockModel:
    """Recompute receipt invariants against the exact referenced sessions."""

    if receipt.reference.session_id != reference_reader.manifest.session_id:
        raise ValueError("clock-sync reference session ID mismatch")
    if receipt.target.session_id != target_reader.manifest.session_id:
        raise ValueError("clock-sync target session ID mismatch")

    if (
        receipt.reference.bundle_sha256
        != session_evidence_sha256(reference_reader)
    ):
        raise ValueError("clock-sync reference bundle hash mismatch")
    if (
        receipt.target.bundle_sha256
        != session_evidence_sha256(target_reader)
    ):
        raise ValueError("clock-sync target bundle hash mismatch")

    reference_events = list(
        reference_reader.iter_stream(receipt.reference.stream)
    )
    target_events = list(target_reader.iter_stream(receipt.target.stream))
    if not reference_events:
        raise ValueError("clock-sync reference stream is missing or empty")
    if not target_events:
        raise ValueError("clock-sync target stream is missing or empty")

    reference_points = {
        (event.sequence, event.canonical_time_ns)
        for event in reference_events
    }
    target_points = {
        (event.sequence, event.device_time_ns)
        for event in target_events
    }
    for landmark in receipt.landmarks:
        if (
            landmark.reference_sequence,
            landmark.reference_time_ns,
        ) not in reference_points:
            raise ValueError(
                f"clock-sync reference landmark {landmark.index} "
                "does not exist in the referenced stream"
            )
        if (
            landmark.target_sequence,
            landmark.target_device_time_ns,
        ) not in target_points:
            raise ValueError(
                f"clock-sync target landmark {landmark.index} "
                "does not exist in the referenced stream"
            )

    observations = list(receipt.observations)
    recomputed_coverage = landmark_coverage(
        observations,
        target_events,
    )
    if recomputed_coverage != receipt.coverage:
        raise ValueError("clock-sync landmark coverage does not recompute")
    if not recomputed_coverage.passed:
        raise ValueError(
            "clock-sync receipt does not satisfy start/middle/end coverage"
        )

    recomputed_model = estimate_clock_model(
        observations,
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )
    stored = receipt.clock_model
    if (
        not math.isclose(
            recomputed_model.slope,
            stored.slope,
            rel_tol=1e-12,
            abs_tol=1e-15,
        )
        or not math.isclose(
            recomputed_model.intercept_ns,
            stored.intercept_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        or not math.isclose(
            recomputed_model.residual_rms_ns,
            stored.residual_rms_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        or recomputed_model.observations_used != stored.observations_used
    ):
        raise ValueError("clock-sync affine model does not recompute")

    return recomputed_model


def read_windows(path: str | Path) -> list[dict[str, object]]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise TypeError("synchronization windows must be a JSON list")

    windows: list[dict[str, object]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(
                f"synchronization window {index} must be an object"
            )
        windows.append(dict(item))
    return windows


def write_clock_sync(
    reference_session: str | Path,
    target_session: str | Path,
    windows_path: str | Path,
    output_path: str | Path,
    *,
    reference_stream: str,
    target_stream: str,
    reference_peak_keys: tuple[str, ...] = ("ax", "ay", "az"),
    target_peak_keys: tuple[str, ...] = ("ax", "ay", "az"),
    allow_legacy_pod_windows: bool = False,
) -> ClockSyncReceipt:
    windows = read_windows(windows_path)
    receipt = derive_clock_sync(
        SessionReader(reference_session),
        SessionReader(target_session),
        windows,
        reference_stream=reference_stream,
        target_stream=target_stream,
        reference_peak_keys=reference_peak_keys,
        target_peak_keys=target_peak_keys,
        allow_legacy_pod_windows=allow_legacy_pod_windows,
    )

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def clock_observations_from_json(
    path: str | Path | None,
) -> list[ClockObservation]:
    """Read both legacy P1 observation lists and clock-sync v1 receipts."""

    if path is None:
        return []

    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        observations_raw = raw.get("observations")
        if not isinstance(observations_raw, list):
            raise TypeError(
                "clock-sync receipt must contain an observations list"
            )
        raw = observations_raw

    if not isinstance(raw, list):
        raise TypeError(
            "clock observations must be a JSON list or clock-sync receipt"
        )

    observations: list[ClockObservation] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(f"clock observation {index} must be an object")
        observations.append(
            ClockObservation(
                device_time_ns=int(item["device_time_ns"]),
                session_time_ns=int(item["session_time_ns"]),
                round_trip_ns=int(item.get("round_trip_ns", 0)),
            )
        )
    return observations


def load_clock_sync_receipt(path: str | Path) -> ClockSyncReceipt:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("clock-sync receipt must contain a JSON object")
    if raw.get("schema_version") != CLOCK_SYNC_SCHEMA_VERSION:
        raise ValueError("unsupported clock-sync receipt schema")

    def identity(name: str) -> SessionClockIdentity:
        value = raw.get(name)
        if not isinstance(value, dict):
            raise TypeError(f"clock-sync receipt {name} must be an object")
        hashes = value.get("source_evidence_sha256")
        return SessionClockIdentity(
            session_id=str(value["session_id"]),
            stream=str(value["stream"]),
            bundle_sha256=str(value["bundle_sha256"]),
            source_evidence_sha256=(
                {str(k): str(v) for k, v in hashes.items()}
                if isinstance(hashes, dict)
                else {}
            ),
        )

    landmarks_raw = raw.get("landmarks")
    if not isinstance(landmarks_raw, list):
        raise TypeError("clock-sync receipt landmarks must be a list")
    landmarks = tuple(
        ClockLandmark(
            index=int(item["index"]),
            reference_window_start_ns=int(item["reference_window_start_ns"]),
            reference_window_end_ns=int(item["reference_window_end_ns"]),
            target_window_start_ns=int(item["target_window_start_ns"]),
            target_window_end_ns=int(item["target_window_end_ns"]),
            reference_time_ns=int(item["reference_time_ns"]),
            target_device_time_ns=int(item["target_device_time_ns"]),
            uncertainty_ns=int(item["uncertainty_ns"]),
            reference_sequence=int(item["reference_sequence"]),
            target_sequence=int(item["target_sequence"]),
            reference_peak_value=float(item["reference_peak_value"]),
            target_peak_value=float(item["target_peak_value"]),
        )
        for item in landmarks_raw
        if isinstance(item, dict)
    )
    if len(landmarks) != len(landmarks_raw):
        raise TypeError("clock-sync landmark must be an object")

    coverage_raw = raw.get("coverage")
    if not isinstance(coverage_raw, dict):
        raise TypeError("clock-sync coverage must be an object")
    coverage = LandmarkCoverage(
        passed=bool(coverage_raw["passed"]),
        observation_count=int(coverage_raw["observation_count"]),
        target_capture_start_ns=int(
            coverage_raw["target_capture_start_ns"]
        ),
        target_capture_end_ns=int(
            coverage_raw["target_capture_end_ns"]
        ),
        observation_span_ns=int(coverage_raw["observation_span_ns"]),
        observation_span_fraction=float(
            coverage_raw["observation_span_fraction"]
        ),
        first_position_fraction=float(
            coverage_raw["first_position_fraction"]
        ),
        last_position_fraction=float(
            coverage_raw["last_position_fraction"]
        ),
        has_middle_landmark=bool(
            coverage_raw["has_middle_landmark"]
        ),
    )

    model_raw = raw.get("clock_model")
    if not isinstance(model_raw, dict):
        raise TypeError("clock-sync clock_model must be an object")
    model = ClockModel(
        slope=float(model_raw["slope"]),
        intercept_ns=float(model_raw["intercept_ns"]),
        residual_rms_ns=float(model_raw["residual_rms_ns"]),
        observations_used=int(model_raw["observations_used"]),
    )

    metric = raw.get("peak_metric")
    if not isinstance(metric, dict):
        raise TypeError("clock-sync peak_metric must be an object")

    return ClockSyncReceipt(
        reference=identity("reference"),
        target=identity("target"),
        landmarks=landmarks,
        coverage=coverage,
        clock_model=model,
        windows_sha256=str(raw["windows_sha256"]),
        reference_peak_keys=tuple(
            str(value)
            for value in metric.get("reference_keys", [])
        ),
        target_peak_keys=tuple(
            str(value)
            for value in metric.get("target_keys", [])
        ),
        schema_version=str(raw["schema_version"]),
    )
