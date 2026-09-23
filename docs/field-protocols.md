# MotionOS Physical Field Protocol Index

This document is the short operator-facing index for MotionOS physical evidence.
The detailed runbooks are authoritative when they disagree with this summary.

Protocol names are stable evidence identifiers. Do not reuse a protocol number
for a different sensor or experiment.

## P0 — Apple Watch + iPhone qualification

Hardware: paired iPhone + Apple Watch.

Purpose:
- qualify durable Watch IMU/HR capture;
- exercise background/lock/separation behavior;
- preserve the real Watch journal and iPhone environment evidence.

Run:
- P0-A: 10-minute shakedown;
- P0-B: >=30-minute qualification.

Authoritative procedure:
`docs/p0-physical-runbook.md`

P0 does not qualify cross-device timing or biomechanics.

## P1 — equipment-pod qualification

Hardware: iPhone + Watch + MetaMotionS equipment pod.

Purpose:
- qualify durable equipment IMU capture;
- verify mount/profile metadata;
- recover flash evidence across BLE interruption;
- later map equipment board time to Watch/reference time.

Include:
- stationary board;
- repeatable orientation excitation;
- start/middle/end shared physical synchronization landmarks;
- deliberate BLE separation and recovery.

Authoritative procedure:
`docs/p1-physical-runbook.md`

## P2 — bilateral insole qualification

Hardware: bilateral pressure/foot-IMU insoles.

Purpose:
- qualify controlled and field bilateral evidence;
- check unloaded behavior;
- check a predeclared known static load;
- quantify don/doff repeatability;
- preserve left/right identity and source-export provenance.

P2 uses two distinct source sessions:
- controlled >=10 minutes;
- field >=30 minutes.

Authoritative procedure:
`docs/p2-opengo-runbook.md`

P2 does not establish full 3D ground-reaction force.

## P5A — iPhone camera + Vision 3D qualification

Hardware: rear iPhone camera on a rigid mount.

Purpose:
- preserve source video and exact video PTS;
- capture raw Vision 3D teacher evidence;
- expose frame/pose drops;
- map camera/video time to the Watch/reference clock.

Include:
- >=10 minutes capture;
- fixed lens/orientation;
- start/middle/end shared synchronization movements;
- full-body visibility through the calibration movement block.

Authoritative procedure:
`docs/p5a-camera-runbook.md`

Vision output is teacher/validation evidence, not ground-truth biomechanics.

## M0-B5 — first combined longboard calibration ride

Hardware:
- Apple Watch;
- MetaMotionS equipment pod;
- bilateral insoles;
- fixed iPhone camera;
- optional personalized body-model artifact.

This is an integration run, not a new sensor qualification protocol. P0, P1,
P2, and P5A must retain their own receipts and raw evidence.

Movement blocks:
- quiet stance;
- pushes;
- straight glide;
- repeated left carves;
- repeated right carves;
- front/rear load shifts;
- foot repositioning;
- controlled braking/stopping;
- deliberate stabilization perturbations;
- shared synchronization movements near start, middle, and end.

Authoritative procedure:
`docs/first-multimodal-calibration-ride.md`

Use `scripts/process_calibration_run.sh` for debugging incomplete evidence.
Use `scripts/finalize_m0_run.sh` only for strict closure attempts.

## Repeatability campaign

After the first combined ride succeeds, repeat a shortened calibration protocol
on at least three separate days.

Remount sensors normally each day rather than preserving the exact placement.

Quantify:
- clock residual/drift repeatability;
- sensor-to-segment and equipment-mount sensitivity;
- pressure zero and static-load drift;
- camera/body-model registration repeatability;
- session-to-session feature stability;
- failure rate and missing-data patterns.

Do not random-split adjacent frames and call that repeatability evidence.

## M1 calibration primitives

When practical, prepend the same common movement primitives to later calibration
sessions so M1 can compare modalities under simpler, more observable motion:

- quiet stance;
- A/T pose;
- left/right weight shift;
- front/rear weight shift;
- squat;
- heel raises;
- single-leg stance;
- step initiation/contact;
- wrist/device rotations about each axis;
- shared synchronization choreography;
- slow/medium/fast repetitions.

These primitives add calibration value but do not change the M0 closure contract.
