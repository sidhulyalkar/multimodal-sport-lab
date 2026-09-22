# MotionOS Fault Injection

A capture platform that only tests clean data is not qualified for field use.

The Python test harness can deliberately inject:

- dropped sequence numbers
- exact duplicate samples
- local timestamp reversal
- long transport/acquisition gaps
- degraded synchronization quality

These failures are intentionally simple and deterministic. They test the QC contract before we add more realistic stochastic models.

## Next fault models

Physical-device work should add captured examples of:

- BLE disconnect with successful local-log recovery
- BLE disconnect without recovery
- Watch app background/foreground transition
- phone lock
- battery brownout
- IMU saturation
- pressure sensor saturation
- pressure zero drift
- mount orientation mistake
- left/right insole swap
- camera frame loss
- occluded body joints
- session clock discontinuity
- duplicate device identity

Each real failure should become a permanent regression fixture once observed.
