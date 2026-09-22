# Equipment Pod Adapter Contract

Vendor SDK objects stop at the adapter boundary.

## Raw stream contract

For MetaMotionS, acceleration and gyroscope samples have independent device
timestamps. MotionOS therefore preserves two raw stream families:

```text
/equipment/imu/accel
/equipment/imu/gyro
```

A combined `/equipment/imu` event is reserved for hardware or a later
reconstruction step that can justify a synchronized six-axis observation.

We do **not** pair BLE packet arrivals and pretend they were sampled
simultaneously.

## Timestamp authority

There are two distinct timing regimes:

### Live preview

The MetaWear SDK timestamps live BLE samples when the host receives the packet.
That is useful for UI feedback, but BLE scheduling jitter makes it unsuitable as
the authoritative pod clock.

Live preview samples therefore stay outside the scientific session journal.

### Recovered flash log

MetaMotionS flash samples expose `tickMs`, the board clock in milliseconds
since reset. Recovered MotionOS events use:

```text
device_time_ns = tickMs * 1_000_000
timestamp_basis = "device_tick_ms"
```

This device clock becomes the input to the later affine clock-mapping step.

## Units

MotionOS converts vendor units at the adapter boundary:

- accelerometer: `g` → `m/s²`
- gyroscope: `degrees/s` → `rad/s`

Raw sensor-frame vectors are never discarded.

After mount calibration an accel event can contain:

```json
{
  "ax": 0.1,
  "ay": 0.2,
  "az": 9.8,
  "accel_sensor": [0.1, 0.2, 9.8],
  "accel_equipment": [0.2, -0.1, 9.8],
  "equipment_id": "longboard-001",
  "equipment_type": "longboard",
  "mount_id": "center-deck-v1",
  "frame_convention": "+X forward,+Y left,+Z up"
}
```

Gyroscope events use the analogous `gyro_sensor` and `gyro_equipment`
fields.

This redundancy is intentional. Raw values are evidence; calibrated values are
a deterministic interpretation.

## MetaMotionS operating modes

The pinned MetaWear SDK models live streaming and on-device logging as mutually
exclusive high-level device states. MotionOS respects that constraint.

### Preview mode

- stream BMI270 accelerometer and gyroscope over BLE;
- show mounting/orientation feedback;
- inspect signal magnitude and clipping risk;
- do not treat BLE arrival time as device time.

### Recording mode

- stop preview first;
- optionally clear flash only through an explicit user action;
- arm BMI270 accelerometer and gyroscope flash loggers;
- let the board record autonomously;
- BLE presence is not required for evidence continuity.

### Recovery mode

- reconnect after link loss;
- enumerate/recover logger registrations;
- stop both loggers;
- flush the MetaMotionS partial NAND page;
- download typed accelerometer and gyroscope logs;
- retain each sample's `tickMs`;
- verify both streams are non-empty;
- only clear flash after both downloads succeed.

The SDK is pinned to upstream commit
`7dd2a5dbddafb2f8d583cb8d018be476d8ee9a71`.

## Dropout semantics

A BLE disconnect is not automatically a data-loss event.

MotionOS distinguishes:

- `preview_link_lost`
- `recording_link_lost`
- `local_logger_continues`
- `reconnected`
- `logger_registry_recovered`
- `local_log_downloaded`
- `reconciliation_complete`
- `unrecoverable_gap`

Only the final state represents confirmed missing evidence.

## Current claim boundary

The adapter and host app can be compile-qualified without hardware.

P1 is not scientifically qualified until a physical MetaMotionS run proves:

1. both flash streams record at the requested rates;
2. deliberate phone separation does not stop the board logger;
3. logger recovery succeeds after reconnect;
4. downloaded sequence/tick timing is internally coherent;
5. start/middle/end synchronization impulses support a measured clock model;
6. the same mount calibration is stable before and after the ride.
