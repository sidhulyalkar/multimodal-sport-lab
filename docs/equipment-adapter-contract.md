# Equipment Pod Adapter Contract

Vendor SDK objects stop at the adapter boundary.

The downstream MotionOS stream remains:

```text
/equipment/imu
```

with one canonical `SensorEvent` envelope.

## Payload principle: raw + calibrated

Never replace vendor/raw vectors with calibrated values.

A normalized payload contains both:

```json
{
  "ax": 0.1,
  "ay": 0.2,
  "az": 9.8,
  "gx": 0.01,
  "gy": 0.02,
  "gz": 0.03,

  "accel_sensor": [0.1, 0.2, 9.8],
  "gyro_sensor": [0.01, 0.02, 0.03],

  "accel_equipment": [0.2, -0.1, 9.8],
  "gyro_equipment": [0.02, -0.01, 0.03],

  "equipment_id": "longboard-001",
  "equipment_type": "longboard",
  "mount_id": "center-deck-v1",
  "frame_convention": "+X forward,+Y left,+Z up"
}
```

This is intentionally redundant. Raw values are evidence; calibrated values are a deterministic interpretation.

## MetaMotionS adapter responsibilities

The future MbientLab adapter should:

1. discover a selected MetaMotionS;
2. verify model/hardware revision;
3. expose battery/RSSI/device identity;
4. configure accelerometer and gyro ranges/rates;
5. stream a live preview;
6. arm on-device flash logging;
7. preserve device/sample timing;
8. recover the local log after disconnect;
9. translate each sample into `SensorEvent`;
10. apply the saved equipment profile without discarding raw vectors.

The active MbientLab Swift SDK supports MetaMotionS, live sensor streams, and on-device logging/recovery. Pin a specific SDK revision when implementation begins; do not track an unpinned branch in production.

## Dropout semantics

A BLE disconnect is not automatically a data loss event.

MotionOS should distinguish:

- `live_link_lost`
- `local_logger_continues`
- `reconnected`
- `local_log_recovered`
- `reconciliation_complete`
- `unrecoverable_gap`

Only the final state represents confirmed missing evidence.
