# MotionOS Verification Matrix

MotionOS uses an evidence ladder. A feature is not "tested" merely because the happy path renders.

## Layer 0 — contract tests
- event JSON round trip
- schema version compatibility
- units and payload validation
- sequence monotonicity
- manifest/session identity
- cross-language Swift/Python fixtures

## Layer 1 — deterministic simulation
Inject:
- clock offset
- clock drift
- packet loss
- duplicates
- reordering
- Bluetooth gaps
- battery shutdown
- saturation
- sensor bias
- camera frame drops

Assert that QC identifies each failure.

## Layer 2 — adapter bench tests
For every physical device:
- identity discovery
- reconnect
- sample-rate verification
- units/ranges
- timestamp monotonicity
- local logging
- battery behavior
- cold start
- app background/foreground
- phone screen lock
- airplane-mode interruption

## Layer 3 — synchronization tests
- repeated network time probes
- start/mid/end physical impulse
- >=30-minute drift
- cross-device residual distribution
- detect clock discontinuities
- determine whether affine or piecewise mapping is needed

## Layer 4 — calibration tests
### IMU
- six static orientations
- known-angle rotation jig where practical
- repeated board level/tilt
- high-g saturation test using safe controlled motion

### Pressure
- unloaded zero
- known static masses where safe
- heel/toe loading
- medial/lateral loading
- repeated load/unload hysteresis
- left/right identity
- sensor saturation

### Camera pose
- static poses
- occlusion
- distance/framing variation
- lighting variation
- phone orientation
- compare known segment lengths to body-model constraints

## Layer 5 — end-to-end sport protocol
For longboarding:
- quiet stance
- push
- coast
- left carve
- right carve
- foot reposition
- brake
- stop
- controlled perturbation/recovery

Every event receives a video label during calibration trials.

## Layer 6 — model validation
Split by session/day, not random windows.

Metrics:
- event precision/recall/F1
- joint position error
- joint angle error
- board orientation error
- COP error
- calibration drift
- uncertainty calibration / coverage

Always report wearable-only separately from wearable+camera.

## Layer 7 — UI verification
For every screen:
- no devices
- partial devices
- all devices
- recording
- paused
- disconnected
- degraded sync
- low battery
- stale data
- corrupted session
- very long session
- missing camera
- denied HealthKit permission

Snapshot/screenshot tests should cover these canonical states.

## Layer 8 — field abuse
- vibration
- sweat
- cold
- heat
- rain/splash within hardware rating
- board impact
- phone out of BLE range
- Watch/phone reconnect
- accidental app termination
- storage pressure

## Release gate
A build may call itself M0 field-qualified only when:
- required streams are present
- data-quality receipt passes
- timing receipt passes
- calibration receipt exists
- raw session is replayable
- failure modes are surfaced in UI rather than silently hidden
