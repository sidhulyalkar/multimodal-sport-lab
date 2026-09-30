from __future__ import annotations

import json
import math
from pathlib import Path

from .indo_board_reconstruction import load_skeleton_frames
from .schema import SensorEvent
from .uncertainty_fusion import (
    ScalarObservation,
    inverse_variance_fuse_scalar,
)


def build_wrist_acceleration_fusion(
    skeleton_geometry_path: str | Path,
    skeleton_correspondences_path: str | Path,
    watch_journal_path: str | Path,
    output_path: str | Path,
    *,
    watch_acceleration_std_m_s2: float,
    vision_acceleration_std_m_s2: float,
    maximum_acceleration_rate_m_s3: float,
    maximum_time_delta_ms: float = 20.0,
    wrist_side: str | None = None,
) -> dict[str, object]:
    for label, value in (
        ("watch_acceleration_std_m_s2", watch_acceleration_std_m_s2),
        ("vision_acceleration_std_m_s2", vision_acceleration_std_m_s2),
        ("maximum_acceleration_rate_m_s3", maximum_acceleration_rate_m_s3),
        ("maximum_time_delta_ms", maximum_time_delta_ms),
    ):
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"{label} must be positive")

    frames = load_skeleton_frames(
        skeleton_geometry_path,
        skeleton_correspondences_path,
    )
    watch_events = _watch_events(watch_journal_path)
    resolved_side = wrist_side or _wrist_side(watch_events)
    if resolved_side not in {"left", "right"}:
        raise ValueError("wrist_side must be left or right")

    vision = _vision_acceleration(
        frames,
        side=resolved_side,
    )
    watch = _watch_acceleration(watch_events)
    pairs = _nearest_pairs(
        vision,
        watch,
        maximum_time_delta_ms=maximum_time_delta_ms,
    )
    if not pairs:
        raise ValueError(
            "no Watch/vision wrist acceleration pairs survived timing gate"
        )

    fused_samples: list[dict[str, object]] = []
    for vision_item, watch_item in pairs:
        fused = inverse_variance_fuse_scalar(
            [
                ScalarObservation(
                    source_id="vision",
                    quantity_id="wrist_linear_acceleration_magnitude",
                    value=vision_item["value"],
                    variance=vision_acceleration_std_m_s2**2,
                    session_time_ns=vision_item["time_ns"],
                    timing_uncertainty_ns=vision_item[
                        "timing_uncertainty_ns"
                    ],
                    maximum_rate_per_s=
                        maximum_acceleration_rate_m_s3,
                ),
                ScalarObservation(
                    source_id="apple-watch",
                    quantity_id="wrist_linear_acceleration_magnitude",
                    value=watch_item["value"],
                    variance=watch_acceleration_std_m_s2**2,
                    session_time_ns=watch_item["time_ns"],
                    timing_uncertainty_ns=0.0,
                    maximum_rate_per_s=
                        maximum_acceleration_rate_m_s3,
                ),
            ],
            maximum_source_time_delta_ms=maximum_time_delta_ms,
        )
        fused_samples.append(
            {
                "time_ns": fused.session_time_ns,
                "vision_m_s2": vision_item["value"],
                "watch_m_s2": watch_item["value"],
                "fused_m_s2": fused.value,
                "fused_std_m_s2": fused.standard_deviation,
                "time_delta_ms": (
                    watch_item["time_ns"] - vision_item["time_ns"]
                )
                / 1e6,
                "vision_timing_uncertainty_ms": (
                    vision_item["timing_uncertainty_ns"] / 1e6
                ),
            }
        )

    residuals = [
        sample["watch_m_s2"] - sample["vision_m_s2"]
        for sample in fused_samples
    ]
    rms_residual = math.sqrt(
        sum(value * value for value in residuals)
        / len(residuals)
    )

    result: dict[str, object] = {
        "schema_version": "motionos.wrist-acceleration-fusion.v1",
        "wrist_side": resolved_side,
        "quantity": "wrist_linear_acceleration_magnitude",
        "units": "m/s^2",
        "parameters": {
            "watch_acceleration_std_m_s2":
                watch_acceleration_std_m_s2,
            "vision_acceleration_std_m_s2":
                vision_acceleration_std_m_s2,
            "maximum_acceleration_rate_m_s3":
                maximum_acceleration_rate_m_s3,
            "maximum_time_delta_ms": maximum_time_delta_ms,
        },
        "sample_count": len(fused_samples),
        "watch_minus_vision_rms_m_s2": rms_residual,
        "samples": fused_samples,
        "claim_boundary": (
            "This secondary fusion compares gravity-subtracted Watch "
            "linear-acceleration magnitude with the second derivative of "
            "triangulated wrist position. It is an orientation-invariant "
            "cross-modal consistency estimate, not a replacement for the "
            "camera-derived board/COM technique metrics."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _vision_acceleration(
    frames: tuple[object, ...],
    *,
    side: str,
) -> tuple[dict[str, float | int], ...]:
    selected: list[
        tuple[int, tuple[float, float, float], float]
    ] = []
    target = f"{side}wrist"
    for frame in frames:
        joints = frame.joints_m
        match = next(
            (
                point
                for name, point in joints.items()
                if _canonical(name) == target
            ),
            None,
        )
        if match is not None:
            selected.append(
                (
                    frame.time_ns,
                    match,
                    frame.timing_uncertainty_ms,
                )
            )

    values: list[dict[str, float | int]] = []
    for first, middle, last in zip(
        selected,
        selected[1:],
        selected[2:],
        strict=False,
    ):
        dt_first = (middle[0] - first[0]) / 1e9
        dt_second = (last[0] - middle[0]) / 1e9
        if dt_first <= 0 or dt_second <= 0:
            continue
        velocity_first = tuple(
            (middle[1][axis] - first[1][axis]) / dt_first
            for axis in range(3)
        )
        velocity_second = tuple(
            (last[1][axis] - middle[1][axis]) / dt_second
            for axis in range(3)
        )
        acceleration_dt = (dt_first + dt_second) / 2
        acceleration = tuple(
            (
                velocity_second[axis] - velocity_first[axis]
            )
            / acceleration_dt
            for axis in range(3)
        )
        values.append(
            {
                "time_ns": middle[0],
                "value": math.sqrt(
                    sum(value * value for value in acceleration)
                ),
                "timing_uncertainty_ns": round(
                    middle[2] * 1e6
                ),
            }
        )
    if not values:
        raise ValueError(
            f"insufficient reconstructed {side} wrist frames "
            "for acceleration"
        )
    return tuple(values)


def _watch_acceleration(
    events: tuple[SensorEvent, ...],
) -> tuple[dict[str, float | int], ...]:
    values: list[dict[str, float | int]] = []
    for event in events:
        if event.stream != "/body/watch/imu":
            continue
        try:
            components = (
                float(event.payload["user_ax"]),
                float(event.payload["user_ay"]),
                float(event.payload["user_az"]),
            )
        except (KeyError, TypeError, ValueError):
            continue
        values.append(
            {
                "time_ns": event.device_time_ns,
                "value": math.sqrt(
                    sum(value * value for value in components)
                ),
            }
        )
    if not values:
        raise ValueError(
            "Watch journal contains no gravity-subtracted acceleration"
        )
    return tuple(values)


def _nearest_pairs(
    vision: tuple[dict[str, float | int], ...],
    watch: tuple[dict[str, float | int], ...],
    *,
    maximum_time_delta_ms: float,
) -> tuple[
    tuple[dict[str, float | int], dict[str, float | int]],
    ...,
]:
    max_delta_ns = round(maximum_time_delta_ms * 1e6)
    pairs: list[
        tuple[dict[str, float | int], dict[str, float | int]]
    ] = []
    watch_index = 0
    for vision_item in vision:
        vision_time = int(vision_item["time_ns"])
        while (
            watch_index + 1 < len(watch)
            and abs(
                int(watch[watch_index + 1]["time_ns"])
                - vision_time
            )
            <= abs(
                int(watch[watch_index]["time_ns"])
                - vision_time
            )
        ):
            watch_index += 1
        watch_item = watch[watch_index]
        if abs(int(watch_item["time_ns"]) - vision_time) <= max_delta_ns:
            pairs.append((vision_item, watch_item))
    return tuple(pairs)


def _watch_events(path: str | Path) -> tuple[SensorEvent, ...]:
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
                f"invalid Watch event at line {line_number}"
            ) from exc
    return tuple(events)


def _wrist_side(events: tuple[SensorEvent, ...]) -> str:
    for event in events:
        if event.stream != "/meta/watch":
            continue
        value = str(event.payload.get("wrist_location", ""))
        if value in {"left", "right"}:
            return value
    raise ValueError(
        "Watch metadata does not declare left/right wrist placement"
    )


def _canonical(name: str) -> str:
    value = "".join(
        character
        for character in name.lower()
        if character.isalnum()
    )
    return value.removesuffix("joint")
