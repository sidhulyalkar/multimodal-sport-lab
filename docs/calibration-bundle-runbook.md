# M0-B4 Calibration Bundle Runbook

This stage turns independently preserved Watch, equipment-pod, bilateral
insole, and camera sessions into one **auditable temporal view**.

It does not rewrite any source journal, stream file, or exported vendor file.

## Core rule

Every non-reference source keeps its own raw clock:

```text
raw device/export time
    ↓
explicit physical landmark correspondences
    ↓
affine clock model
    ↓
derived Watch/reference time used only during synchronized replay
```

The calibration manifest stores the mapping and the exact source hashes.

## Reference clock

For the first wearable-only calibration run, use the Watch MotionOS session as
the reference.

Reference-event time is:

```text
event.session_time_ns, when already present
otherwise event.device_time_ns
```

Target-event mapping always starts from the target's raw
`device_time_ns`.

An existing target `session_time_ns` never silently overrides the newly
qualified calibration mapping.

## Shared physical landmarks

Create a distinctive shared impulse near:

1. the start of the run;
2. the middle of the run;
3. the end of the run.

For each source pair, define narrow independent search windows.

Do not run unconstrained full-recording peak matching and then choose the
correspondence that looks best.

A generic window file uses:

```json
{
  "reference_start_ns": 1000000000,
  "reference_end_ns": 1600000000,
  "target_start_ns": 500000000,
  "target_end_ns": 1100000000,
  "uncertainty_ns": 5000000
}
```

See:

```text
examples/clock-sync-windows.example.json
```

## Equipment pod → Watch

```bash
motionos derive-clock-sync \
  data/p0/<watch-session> \
  data/p1/<pod-session> \
  equipment-sync-windows.json \
  data/sync/equipment-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /equipment/imu/accel
```

The old command remains a compatibility alias:

```bash
motionos derive-p1-sync ...
```

Legacy P1 window files using `pod_start_ns` / `pod_end_ns` are still
accepted by that alias.

## OpenGo bilateral insoles → Watch

The imported OpenGo bilateral session uses one exported relative-time column for
both feet.

Therefore one clock model maps the **OpenGo session clock** to Watch time.

Use either foot IMU stream for the shared impulse, for example:

```bash
motionos derive-clock-sync \
  data/p0/<watch-session> \
  data/p2/<insole-session> \
  insole-sync-windows.json \
  data/sync/insoles-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /body/left_foot/imu
```

This does not erase left/right sparse rows. Both feet retain their own events
and missing-sample regions on the shared OpenGo time axis.

## iPhone camera → Watch

A qualified camera session preserves raw AVFoundation presentation timestamps
and exposes a derived timing-only stream:

```text
/camera/pose_motion
```

Use the deliberate shared motion near start, middle, and end:

```bash
motionos derive-clock-sync \
  data/p0/<watch-session> \
  data/camera/<camera-session> \
  camera-sync-windows.json \
  data/sync/camera-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /camera/pose_motion \
  --target-keys motion_m
```

The derived `motion_m` signal exists only to make camera timing landmarks
observable. It is not a biomechanical displacement estimate.

## What the clock-sync receipt freezes

Each `motionos.clock-sync.v1` receipt stores:

- reference session ID;
- target session ID;
- reference stream;
- target stream;
- exact MotionOS source-bundle SHA-256 for both sessions;
- original source-file SHA-256 values when available;
- SHA-256 of the declared windows;
- every selected landmark and search window;
- raw target device/export time;
- reference canonical time;
- affine slope/intercept;
- drift in ppm;
- residual RMS;
- model quality;
- start/middle/end coverage result.

All deliberate landmarks are used for the fit.

No RTT-style landmark pruning is applied to deliberate physical
correspondences.

## Structural coverage

A synchronization receipt reports whether:

- the first target landmark is at or before 20% of the target capture;
- at least one middle landmark is between 30% and 70%;
- the final landmark is at or after 80%;
- every landmark lies inside the target capture.

A tiny residual from three clustered landmarks does not satisfy this structural
gate.

## Calibration bundle spec

Create a spec like:

```text
examples/calibration-bundle-spec.example.json
```

Each source contains:

- a unique role;
- a MotionOS session path;
- its qualification receipt, when available;
- a clock-sync receipt for every non-reference source.

Profiles can include:

- equipment mount calibration;
- left/right insole geometry;
- later spatial camera calibration.

The camera session itself is already a normal non-reference source in the
bundle. Spatial camera/world calibration is a separate future artifact.

## Build the bundle

```bash
motionos build-calibration-bundle \
  calibration-spec.json \
  data/calibration/calibration.json
```

The builder verifies:

- each session can be read;
- each session's current source-bundle hash;
- clock-sync reference session ID/hash;
- clock-sync target session ID/hash;
- structural landmark coverage;
- receipt/profile file hashes.

The output stores paths as locators, but hashes and session IDs are the evidence
identity.

## Replay without rewriting raw evidence

```bash
motionos replay-calibration \
  data/calibration/calibration.json \
  --hz 10 \
  --frames 30
```

For every mapped target event replay retains:

```text
raw_device_time_ns
source_session_time_ns, if one existed
mapped_reference_time_ns
mapping_quality
source role/session/stream/sequence
original payload
```

No source event is rewritten.

## Gap report

```bash
motionos calibration-gaps \
  data/calibration/calibration.json
```

MotionOS computes each stream's median mapped interval and reports explicit
regions whose successive timestamps exceed 1.5× that cadence.

Calibration replay frames include the streams whose large timestamp gap overlaps
the current frame.

This is intentionally different from silently holding the last value across a
hole.

## Evidence tampering behavior

A calibration manifest is not a loose playlist.

Replay fails closed if:

- a source session's evidence files change;
- a qualification receipt changes;
- a clock-sync receipt changes;
- a referenced profile changes;
- a session ID no longer matches.

Regenerate the bundle only after intentionally accepting a new source artifact.

## Claim boundary

A calibration bundle demonstrates:

- which exact source bytes were synchronized;
- which physical landmarks defined each correspondence;
- the affine temporal model;
- its observed drift and residual;
- the mapped replay time used downstream.

It does **not** establish:

- Watch physiological accuracy;
- MetaMotionS inertial accuracy;
- insole force/pressure accuracy;
- full 3D ground-reaction force;
- biomechanical interpretation;
- camera pose accuracy;
- clinical validity.

Those are separate evidence layers.

## Next physical gate

Once P0, P1, P2, and camera physical receipts exist:

1. perform one shared calibration run;
2. create start/middle/end landmarks visible in Watch, pod, insoles, and camera;
3. derive pod→Watch, OpenGo→Watch, and camera→Watch receipts;
4. build the calibration bundle;
5. inspect drift/residual and gap reports;
6. replay wrist, equipment, both feet, camera frames, and Vision pose together;
7. preserve every modality's raw time beside the mapped Watch/reference time.
