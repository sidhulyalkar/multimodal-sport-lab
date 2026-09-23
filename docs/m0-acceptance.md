# MotionOS M0 Acceptance Gates

M0 is split into a software evidence gate and a physical-device qualification gate so simulation cannot be mistaken for hardware validation.

## M0-A: capture substrate — implemented in this repository

- [x] Versioned multimodal event envelope.
- [x] Append-only per-stream journals with sequence numbers.
- [x] Device→session affine clock estimation including drift.
- [x] Physical impulse cross-check utility.
- [x] Calibration and field session modes.
- [x] Bilateral pressure + foot-IMU topics.
- [x] Equipment-IMU and Watch topics.
- [x] Camera 3D-pose teacher topic.
- [x] Personalized body-model v2 validation and hash provenance.
- [x] Auditable Vision-to-personalized-body similarity registration.
- [x] Synchronized replay frames.
- [x] Per-stream rate/gap/drop/sync QC.
- [x] Required-stream validation gate.
- [x] Deterministic end-to-end simulator.
- [x] Optional MCAP export.
- [x] Real iPhone + watchOS host application targets.
- [x] MetaMotionS durable flash-ingress software path.
- [x] Bilateral OpenGo exported-evidence ingress.
- [x] iPhone video + Vision 3D pose evidence path.
- [x] Hash-verified calibration bundle, run report, and Replay Lab export.
- [x] Operator field-run journal and evidence validation.
- [x] Strict M0 closure validator that rejects non-qualified receipts.
- [x] CI tests and lint.

## M0-B: physical-device qualification — must use real hardware

- [ ] watchOS HealthKit/Core Motion recorder writes the M0 contract.
- [ ] iPhone coordinator starts/stops and persists one real session.
- [ ] Selected equipment IMU adapter survives dropouts via local recording or retransmit.
- [ ] Selected pressure insole adapter exposes raw pressure + timestamps.
- [ ] Camera calibration session writes time-aligned pose labels.
- [ ] Clock drift measured over >=30 minute real session.
- [ ] Deliberate sync impulse residual quantified across all inertial devices.
- [ ] Field ride replay demonstrates Watch + equipment + bilateral feet on one timeline.

**Scientific rule:** M0-B stays open until evidence is collected from real
devices. Passing CI, simulators, importers, or the replay UI is not evidence of
hardware timing accuracy.

For a closure attempt, run `bash scripts/finalize_m0_run.sh ...`. A passing
`m0-closure-receipt.json` is the repository-level integration gate; it still
does not upgrade the underlying sensors into biomechanical ground truth.
