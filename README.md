# Multimodal Sport Lab · MotionOS M0

A hardware-agnostic multimodal capture substrate for understanding an athlete interacting with sports equipment.

**M0 goal:** synchronize and preserve Apple Watch, bilateral foot pressure/IMU, equipment IMU, and calibration-camera pose on one replayable timeline, while keeping raw measurements, clock quality, and uncertainty auditable.

## Why this repository exists

Most fitness systems collapse very different sports into distance, heart rate, and calories. MotionOS instead treats the athlete + equipment as a dynamical system. M0 is the data foundation needed before training pose, balance, technique, or cross-sport models.

```text
 Watch IMU + HR -----\
 Left foot ----------\
 Right foot -----------+--> synchronized session --> replay --> QC --> future ML
 Equipment IMU -------/
 Camera pose (calib) -/
          ^
          |
   personal body model
```

## What is implemented

- Versioned `SensorEvent` contract shared across modalities.
- Append-only per-stream session journals with sequence/drop auditing.
- Affine device clock synchronization with drift estimation.
- Independent deliberate-impulse synchronization check.
- Watch, equipment, bilateral foot pressure/IMU, and camera-pose topics.
- Calibration mode (camera teacher) and field mode (wearables only).
- Personalized body-model validation + auditable Vision-to-body registration.
- Deterministic scan/landmark body-profile authoring + multi-pose registration repeatability.
- Deterministic multimodal simulator with realistic clock offsets/drift.
- Synchronized replay frames and per-stream QC.
- M0 required-stream validation gate.
- Optional MCAP export.
- Swift package mirroring the cross-device event and clock contracts.
- Full P2 controlled + field physical-qualification receipt with a hashed,
  predeclared threshold spec.
- Strict final M0 closure receipt that rejects capture-only or source-mismatched
  evidence.
- CI tests and linting.

See [`docs/m0-acceptance.md`](docs/m0-acceptance.md) for the explicit boundary between software validation and real-hardware qualification.

For the post-M0 measurement, fusion, and cross-sport program, see [`docs/m1-scientific-roadmap.md`](docs/m1-scientific-roadmap.md).
The reproducible M1 experiment/observability/split contract is in [`docs/m1-experiment-contract.md`](docs/m1-experiment-contract.md).
Participant/video/body-scan handling and public-export rules are in [`docs/privacy-data-governance.md`](docs/privacy-data-governance.md).

## Quick start

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'

SESSION=$(motionos simulate --out data --sport longboard --mode calibration --duration 6)
motionos inspect "$SESSION"
motionos validate "$SESSION"
motionos qc "$SESSION"
motionos replay "$SESSION" --hz 5 --frames 8
```

Or run:

```bash
make demo
```

Run the evidence suite:

```bash
make lint
make test
```

Optional MCAP interoperability:

```bash
pip install -e '.[mcap]'
motionos export-mcap "$SESSION" data/session.mcap
```

## M0 data flow

A device keeps its native monotonic clock. Clock probes estimate an affine mapping:

```text
session_time = slope * device_time + intercept
```

The slope captures clock drift; each synchronized event retains a `sync_quality` diagnostic. A deliberate shared motion/impact near session start provides a physical synchronization cross-check independent of network timing.

Every device ultimately emits the same envelope:

```json
{
  "schema_version": "motionos.m0.v1",
  "session_id": "...",
  "device_id": "equipment-001",
  "stream": "/equipment/imu",
  "sequence": 42,
  "device_time_ns": 123456789,
  "session_time_ns": 123460101,
  "sync_quality": 0.98,
  "payload": {"ax": 0.1, "ay": 0.2, "az": 9.8}
}
```

Vendor-specific BLE or HealthKit structures stop at the adapter boundary. Downstream replay and ML never need to know whether the source was Movesense, Moticon, custom hardware, or simulation.

## Repository map

```text
src/motionos/                 Python reference core
  schema.py                   canonical event/manifest contract
  clock.py                    drift-aware device clock estimation
  session.py                  durable append-only session bundles
  simulate.py                 deterministic full-stack synthetic capture
  sync.py                     physical impulse sync checks
  pose.py                     body model + pose alignment
  body_model.py               personalized geometry + similarity registration
  body_authoring.py           scan-profile builder + repeatability reports
  replay.py                   synchronized timeline replay
  qc.py                       rate/gap/drop/sync diagnostics
  validate.py                 M0 evidence gate
  mcap_io.py                  optional MCAP export

apple/MotionOSAppleCapture/   Swift cross-device contract package
docs/                         architecture, contracts, acceptance gates
examples/                     body-model example
tests/                        deterministic evidence suite
```

## Scientific boundary

The simulator validates software invariants, not sensor accuracy. Real Watch, insole, equipment-pod, and camera timing remains a separate physical qualification gate. MotionOS also does not treat plantar pressure as full 3D ground-reaction force or sparse wearables as perfect motion capture. Future pose models should output uncertainty and be validated against calibration video or stronger ground truth.

## Next hardware gate

The software integration path is now in place. The remaining M0-B gate is
physical evidence: run the real Watch/iPhone, MetaMotionS, bilateral insole, and
camera qualification protocols, collect start/middle/end cross-device
landmarks, then execute the first combined longboard calibration ride.

Use `scripts/process_calibration_run.sh` to inspect incomplete runs and
`scripts/finalize_m0_run.sh` only when attempting strict physical closure.
The finalizer produces `m0-closure-receipt.json` and fails until every
physical qualification and provenance dependency is satisfied.
