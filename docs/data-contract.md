# MotionOS M0 Data Contract

Every measurement uses `SensorEvent`:

```json
{
  "schema_version": "motionos.m0.v1",
  "session_id": "m0-longboard-...",
  "device_id": "equipment-001",
  "stream": "/equipment/imu",
  "sequence": 42,
  "device_time_ns": 123456789,
  "session_time_ns": 123460101,
  "sync_quality": 0.98,
  "payload": {"ax": 0.1, "ay": 0.2, "az": 9.8}
}
```

## Time semantics

- `device_time_ns`: device monotonic clock. Never wall-clock time.
- `session_time_ns`: coordinator monotonic epoch after synchronization.
- `sequence`: monotonic within one stream; used to detect drops.
- `sync_quality`: 0..1 diagnostic confidence, never a claim of physical ground-truth accuracy.

## Pressure payload

M0 preserves the raw pressure vector plus useful derived quantities:

```json
{
  "pressure_kpa": [16 values],
  "total_load_fraction": 0.58,
  "cop_x_m": 0.011,
  "cop_y_m": -0.024
}
```

A real adapter should include calibration metadata for sensor locations, units, saturation, and zeroing. M0 does **not** equate plantar pressure with full 3D ground-reaction force.

## 3D pose payload

Calibration pose events carry named joint coordinates in meters and a confidence value. The camera stream is teacher data; it is not required in field mode.
