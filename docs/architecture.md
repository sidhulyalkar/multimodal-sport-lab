# MotionOS M0 Architecture

M0 is a capture substrate, not a sport classifier. Every sensor publishes the same `SensorEvent` envelope, and the phone/coordinator maps device monotonic time into a session monotonic clock.

```text
Apple Watch --------\
Left insole ---------\
Right insole ---------+--> local journals --> clock model --> session bundle --> replay/QC
Equipment IMU -------/
iPhone camera -------/                         |
                                               +--> pose labels (calibration mode)
```

## Design rules

1. **Raw first.** Derived metrics never replace raw measurements.
2. **Local-first recording.** High-rate devices should retain their own stream until transfer is acknowledged.
3. **Affine clock model.** Every device clock is modeled as `session = slope * device + intercept`; slope captures drift.
4. **Physical sync check.** A deliberate impulse near session start independently checks clock alignment across inertial sensors.
5. **Calibration vs field.** Calibration includes camera-derived 3D pose. Field mode is wearable-only.
6. **Uncertainty is data.** `sync_quality` travels with every synchronized sample.
7. **One canonical contract.** Vendor adapters translate into MotionOS topics rather than leaking vendor schemas into downstream code.

## Canonical topics

- `/body/watch/imu`
- `/body/watch/hr`
- `/body/left_foot/imu`
- `/body/left_foot/pressure`
- `/body/right_foot/imu`
- `/body/right_foot/pressure`
- `/equipment/imu`
- `/camera/pose3d`

Future modalities such as EMG, GPS, barometer, strain, or dog ranging add topics without changing the envelope.

## Session bundle

A session is an append-only directory:

```text
<session>/
  manifest.json
  index.json
  metadata/
    clock_models.json
  streams/
    body__watch__imu.jsonl
    ...
```

JSONL is the lossless development format because it is inspectable, diffable, and dependency-free. `motionos export-mcap` provides an interoperability path to MCAP when the optional dependency is installed.
