from __future__ import annotations

import json
from pathlib import Path

from .clock import (
    ClockModel,
    ClockObservation,
    compose_clock_models,
    estimate_clock_model,
    invert_clock_model,
)
from .pose2d_io import fit_embedded_host_clock
from .schema import SensorEvent
from .vision_contract import VisionSessionManifest


def build_vision_clock_bundle(
    vision_session_path: str | Path,
    watch_journal_path: str | Path,
    iphone_camera_journal_path: str | Path,
    external_camera_sync_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    manifest_raw = json.loads(
        Path(vision_session_path).read_text(encoding="utf-8")
    )
    if not isinstance(manifest_raw, dict):
        raise TypeError("vision session must be a JSON object")
    manifest = VisionSessionManifest.from_dict(manifest_raw)

    watch_events = _load_events(watch_journal_path)
    iphone_events = _load_events(iphone_camera_journal_path)
    watch_to_host = _watch_to_host_model(
        manifest,
        watch_events,
    )
    host_to_watch = invert_clock_model(watch_to_host)
    iphone_to_host = fit_embedded_host_clock(iphone_events)

    external_sync = json.loads(
        Path(external_camera_sync_path).read_text(encoding="utf-8")
    )
    if not isinstance(external_sync, dict):
        raise TypeError("external camera sync must be an object")
    if external_sync.get("schema_version") != (
        "motionos.external-camera-sync.v1"
    ):
        raise ValueError("unsupported external camera sync schema")
    action4_to_host = _clock_model(
        external_sync["clock_model"]
    )

    iphone_to_watch = compose_clock_models(
        iphone_to_host,
        host_to_watch,
    )
    action4_to_watch = compose_clock_models(
        action4_to_host,
        host_to_watch,
    )

    result: dict[str, object] = {
        "schema_version": "motionos.vision-clock-bundle.v1",
        "session_id": manifest.session_id,
        "canonical_clock": {
            "source_id": "apple-watch",
            "basis": "CoreMotion monotonic device time",
        },
        "watch_to_host": _clock_dict(watch_to_host),
        "host_to_watch": _clock_dict(host_to_watch),
        "iphone_camera_to_host": _clock_dict(iphone_to_host),
        "action4_to_host": _clock_dict(action4_to_host),
        "iphone_camera_to_watch": _clock_dict(iphone_to_watch),
        "action4_to_watch": _clock_dict(action4_to_watch),
        "claim_boundary": (
            "Camera-to-Watch mappings are affine compositions of measured "
            "clock relations. Residual RMS is propagated as independent "
            "first-order timing uncertainty; this bundle does not replace "
            "the stricter weighted clock-uncertainty artifact used for final "
            "camera-rig qualification."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def load_clock_from_bundle(
    path: str | Path,
    key: str,
) -> ClockModel:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("vision clock bundle must be an object")
    if raw.get("schema_version") != "motionos.vision-clock-bundle.v1":
        raise ValueError("unsupported vision clock bundle schema")
    return _clock_model(raw[key])


def _watch_to_host_model(
    manifest: VisionSessionManifest,
    watch_events: tuple[SensorEvent, ...],
) -> ClockModel:
    host_by_landmark = {
        landmark.landmark_id: landmark.host_monotonic_time_ns
        for landmark in manifest.sync_landmarks
        if landmark.kind == "whole_body_impulse"
    }

    observations: list[ClockObservation] = []
    used_landmarks: set[str] = set()
    for event in watch_events:
        if event.stream != "/sync/vision_cue":
            continue
        landmark_id = str(event.payload.get("landmark_id", ""))
        if (
            landmark_id not in host_by_landmark
            or landmark_id in used_landmarks
        ):
            continue
        observations.append(
            ClockObservation(
                device_time_ns=event.device_time_ns,
                session_time_ns=host_by_landmark[landmark_id],
                round_trip_ns=1,
            )
        )
        used_landmarks.add(landmark_id)

    if len(observations) < 3:
        raise ValueError(
            "Watch-to-host clock fit requires at least three journaled "
            "vision sync cue receipts"
        )
    return estimate_clock_model(
        observations,
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )


def _clock_model(raw: object) -> ClockModel:
    if not isinstance(raw, dict):
        raise TypeError("clock model must be an object")
    return ClockModel(
        slope=float(raw["slope"]),
        intercept_ns=float(raw["intercept_ns"]),
        residual_rms_ns=float(raw["residual_rms_ns"]),
        observations_used=int(raw["observations_used"]),
    )


def _clock_dict(model: ClockModel) -> dict[str, float | int]:
    return {
        "slope": model.slope,
        "intercept_ns": model.intercept_ns,
        "residual_rms_ns": model.residual_rms_ns,
        "residual_rms_ms": model.residual_rms_ns / 1e6,
        "observations_used": model.observations_used,
        "drift_ppm": model.drift_ppm,
    }


def _load_events(path: str | Path) -> tuple[SensorEvent, ...]:
    events: list[SensorEvent] = []
    for line_number, line in enumerate(
        Path(path).read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        try:
            events.append(SensorEvent.from_json(line))
        except Exception as exc:
            raise ValueError(
                f"invalid sensor event at line {line_number}"
            ) from exc
    return tuple(events)
