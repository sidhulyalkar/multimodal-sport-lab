from __future__ import annotations

import math
import random
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .clock import ClockObservation, estimate_clock_model
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionWriter


def _device_time(session_time_ns: int, slope: float, intercept_ns: int) -> int:
    return int((session_time_ns - intercept_ns) / slope)


def _clock_observations(
    *, slope: float, intercept_ns: int, duration_s: float, rng: random.Random
) -> list[ClockObservation]:
    observations: list[ClockObservation] = []
    for index in range(12):
        session_ns = int((index / 11) * duration_s * 1e9)
        device_ns = _device_time(session_ns, slope, intercept_ns)
        jitter = rng.randint(-100_000, 100_000)
        observations.append(
            ClockObservation(
                device_time_ns=device_ns,
                session_time_ns=session_ns + jitter,
                round_trip_ns=rng.randint(300_000, 2_000_000),
            )
        )
    observations.append(
        ClockObservation(
            device_time_ns=_device_time(int(duration_s * 0.5e9), slope, intercept_ns),
            session_time_ns=int(duration_s * 0.5e9) + 12_000_000,
            round_trip_ns=30_000_000,
        )
    )
    return observations


def simulate_session(
    out_root: str | Path,
    *,
    sport: str = "longboard",
    mode: str = "calibration",
    duration_s: float = 6.0,
    seed: int = 7,
) -> Path:
    if duration_s < 2.0:
        raise ValueError("duration_s must be at least 2 seconds so the sync impulse is present")
    rng = random.Random(seed)
    session_id = f"m0-{sport}-{uuid.uuid4().hex[:10]}"
    devices = (
        DeviceDescriptor(
            "watch-001",
            "apple_watch",
            "left_wrist",
            ("/body/watch/imu", "/body/watch/hr"),
        ),
        DeviceDescriptor(
            "left-insole-001",
            "smart_insole",
            "left_foot",
            ("/body/left_foot/imu", "/body/left_foot/pressure"),
        ),
        DeviceDescriptor(
            "right-insole-001",
            "smart_insole",
            "right_foot",
            ("/body/right_foot/imu", "/body/right_foot/pressure"),
        ),
        DeviceDescriptor(
            "equipment-001",
            "imu_pod",
            "equipment",
            ("/equipment/imu",),
        ),
        DeviceDescriptor(
            "iphone-001",
            "iphone",
            "observer",
            ("/camera/pose3d",),
        ),
    )
    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport=sport,
        mode=mode,
        athlete_id="demo-athlete",
        devices=devices,
        body_model="examples/body_model.example.json",
        metadata={"generator": "motionos.simulate", "seed": seed},
    )

    true_clocks = {
        "watch-001": (1.0 + 18e-6, -10_006_000_000),
        "left-insole-001": (1.0 - 24e-6, -10_011_000_000),
        "right-insole-001": (1.0 + 9e-6, -9_993_000_000),
        "equipment-001": (1.0 - 13e-6, -10_004_000_000),
        "iphone-001": (1.0, -10_000_000_000),
    }
    models = {
        device: estimate_clock_model(
            _clock_observations(
                slope=slope,
                intercept_ns=intercept,
                duration_s=duration_s,
                rng=rng,
            )
        )
        for device, (slope, intercept) in true_clocks.items()
    }

    sequences: dict[str, int] = {}

    def append(
        writer: SessionWriter,
        *,
        device: str,
        stream: str,
        session_time_s: float,
        payload: dict[str, object],
    ) -> None:
        true_slope, true_intercept = true_clocks[device]
        true_session_ns = int(session_time_s * 1e9)
        device_ns = _device_time(true_session_ns, true_slope, true_intercept)
        model = models[device]
        seq = sequences.get(stream, 0)
        sequences[stream] = seq + 1
        writer.append(
            SensorEvent(
                session_id=session_id,
                device_id=device,
                stream=stream,
                sequence=seq,
                device_time_ns=device_ns,
                session_time_ns=max(0, model.map(device_ns)),
                sync_quality=model.quality,
                payload=payload,
            )
        )

    with SessionWriter(out_root, manifest) as writer:
        for i in range(int(duration_s * 100)):
            t = i / 100.0
            carve = math.sin(2 * math.pi * 0.55 * t)
            impulse = 8.0 if abs(t - 1.0) < 0.006 else 0.0
            roll = 18.0 * carve
            yaw_rate = 55.0 * math.cos(2 * math.pi * 0.55 * t)
            append(
                writer,
                device="equipment-001",
                stream="/equipment/imu",
                session_time_s=t,
                payload={
                    "ax": 0.6 * carve,
                    "ay": 0.25 * carve,
                    "az": 9.81 + impulse,
                    "gx": math.radians(roll),
                    "gy": 0.0,
                    "gz": math.radians(yaw_rate),
                    "roll_deg": roll,
                },
            )

            left_load = max(0.05, min(0.95, 0.5 - 0.23 * carve))
            right_load = 1.0 - left_load
            for side, load, device in (
                ("left", left_load, "left-insole-001"),
                ("right", right_load, "right-insole-001"),
            ):
                append(
                    writer,
                    device=device,
                    stream=f"/body/{side}_foot/imu",
                    session_time_s=t,
                    payload={
                        "ax": 0.22 * carve,
                        "ay": 0.1 * carve,
                        "az": 9.81 + impulse,
                        "gx": 0.0,
                        "gy": math.radians(roll * 0.7),
                        "gz": math.radians(yaw_rate * 0.5),
                    },
                )
                pressures = [
                    round(load * (0.75 + 0.05 * math.sin(t * 3 + j)) * 100.0, 3)
                    for j in range(16)
                ]
                cop_x = (-0.028 if side == "left" else 0.028) + 0.012 * carve
                cop_y = 0.04 * math.sin(2 * math.pi * 0.3 * t)
                append(
                    writer,
                    device=device,
                    stream=f"/body/{side}_foot/pressure",
                    session_time_s=t,
                    payload={
                        "pressure_kpa": pressures,
                        "total_load_fraction": load,
                        "cop_x_m": cop_x,
                        "cop_y_m": cop_y,
                    },
                )

            if i % 2 == 0:
                append(
                    writer,
                    device="watch-001",
                    stream="/body/watch/imu",
                    session_time_s=t,
                    payload={
                        "ax": 0.3 * carve,
                        "ay": 0.12 * carve,
                        "az": 9.81 + impulse,
                        "gx": math.radians(roll * 0.45),
                        "gy": 0.0,
                        "gz": math.radians(yaw_rate * 0.35),
                    },
                )

            if mode == "calibration" and i % 3 == 0:
                hip_x = 0.08 * carve
                append(
                    writer,
                    device="iphone-001",
                    stream="/camera/pose3d",
                    session_time_s=t,
                    payload={
                        "joints_m": {
                            "pelvis": [hip_x, 0.0, 0.95],
                            "left_ankle": [hip_x - 0.12, 0.03, 0.06],
                            "right_ankle": [hip_x + 0.12, -0.03, 0.06],
                            "left_wrist": [hip_x - 0.32, 0.05, 1.25],
                        },
                        "confidence": 0.94,
                    },
                )

        for second in range(int(duration_s) + 1):
            if second <= duration_s:
                append(
                    writer,
                    device="watch-001",
                    stream="/body/watch/hr",
                    session_time_s=float(second),
                    payload={"bpm": 118 + second * 3},
                )

        writer.write_metadata(
            "clock_models",
            {
                device: {
                    "slope": model.slope,
                    "intercept_ns": model.intercept_ns,
                    "drift_ppm": model.drift_ppm,
                    "residual_rms_ns": model.residual_rms_ns,
                    "quality": model.quality,
                }
                for device, model in models.items()
            },
        )
    return Path(out_root) / session_id
