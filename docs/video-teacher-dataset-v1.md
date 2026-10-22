# MotionOS video-only biomechanics research data v1

Status: implementation of a PRIVATE evidence-candidate index. Not a trained
model, an authorized dataset export, or physical qualification.

## Product and engineering design

Keep the existing iPhone + Watch capture path and source-native timestamps.
Do not introduce a second session format or change the canonical recording
artifacts just to accommodate later model training.

Three user experiences should share one capture substrate:

- **Everyday**: phone/action-camera recording, optional Watch, board tracker,
  immediate replay and validated progress. No research sharing by default.
- **Personal calibration**: guided front/side poses, anthropometry and
  repeated reference drills, with optional multiview video or body scan.
- **Instrumented study**: same recording experience plus optional pressure
  insoles, EMG, equipment IMU and force measurements. Separate informed
  consent and physical sensor qualification are prerequisites.

In every case preserve original camera PTS and frame timing, camera identity,
orientation, requested vs achieved resolution/frame rate, occlusion/quality
diagnostics, source integrity, device-native clocks and calibration identifiers.

Keep body geometry, board coordinates, body pose, sensor readings and
musculoskeletal **model predictions** distinct. Even a faithful scanned mesh
does not measure muscle activation, plantar force or internal composition.

## Existing contracts to reuse

- motionos.m0.v1: canonical source event and session bundle.
- motionos.observability-registry.v1: allowed latent targets, ambiguities,
  explicit reference modalities and teacher eligibility.
- motionos.experiment-manifest.v1: provenance of models and sources.
- motionos.grouped-split.v1: deterministic acquisition-group splits.
- Existing video alignment and clock-sync receipts: timing verification.
- Existing public export gate: private evidence must not become public by default.

No change to deployment targets, signing capabilities, default permissions,
camera device policy or the two-minute Indo Board product protocol is
necessary for this tranche.

## New candidate pairing format

An operator builds a private spec at the path private/spec.json.
For example (paths are local private files and must actually exist):

    {
      "schema_version": "motionos.video-teacher-spec.v1",
      "dataset_id": "indo-pilot",
      "observability_registry": "indo-observability.json",
      "captures": [{
        "sample_id": "trial-001",
        "subject_id": "p-a1b2c3d4",
        "run_id": "r001",
        "day_id": "day001",
        "remount_id": "mount001",
        "camera_view": "front-oblique",
        "sport": "indo_board",
        "task_id": "free-balance",
        "protocol_version": "motionos.indo-board-product-session.v2",
        "video": "private/ride-001.mov",
        "consent": {
          "training_and_evaluation": true,
          "consent_reference": "private-consent-id-001"
        },
        "labels": [{
          "target_id": "left_load_fraction",
          "kind": "sensor_measured",
          "modality": "bilateral_pressure",
          "time_axis": "reference_ns",
          "path": "private/pressure-001.jsonl",
          "alignment_receipt": "private/pressure-video-sync-001.json"
        }]
      }]
    }

The referenced observability registry must declare the target and the
independent reference modality. It must have the same sport.

Build candidate index and verify hashes:

    motionos build-video-teacher-index private/spec.json private/index.json
    motionos verify-video-teacher-index private/index.json
    motionos build-grouped-split private/index.json private/split.json \
      --group-by subject_id --seed video-teacher-pilot
    motionos verify-grouped-split private/split.json private/index.json

The index references existing evidence by relative path, bytes and SHA-256.
It does not copy participant files, validate the underlying private consent
record, check synchronized values or qualify a physiology model. Output
training_ready=false is deliberate. A sensor-derived target is only a
CANDIDATE, even if a sync receipt file is present.

The indexed fields preserve run/day/remount/participant/view/task context for
leakage-aware evaluation. Actual split assignments by subject, not adjacent
video frames, are essential to assess generalization to unseen people.

## Learning topology

1. Train or adapt a general pose/board motion encoder on separately authorized
   video datasets; enforce hold-out by participant and acquisition.
2. Pair a subset with independent pressure/EMG/force reference streams.
3. Label each target as sensor_measured, biomechanical_simulation or
   model_inferred, never silently interchanging these strata.
4. Pretrain with simulation if useful, then test against real measurements.
5. Train small target-specific heads, with calibrated uncertainty and abstention.
6. Use confidence and source provenance in anatomical replay; avoid implying
   that a modeled colored muscle is measured EMG.

## Physical acceptance before an index becomes a training dataset

- Verify the actual participant authorization, intended use and any withdrawal.
- Validate the video clock mapping against the hashed original video.
- Validate sensor clock sync against the hashed source sessions.
- Verify usable time overlap, units, frames, EMG electrode placements,
  force/pressure zeroing and calibration; retain missing-data masks.
- Reject pseudo-labels and modeled simulation as independently measured truth.
- Freeze sample IDs, provenance, annotation review receipts and model versions.
- Use subject-held-out primary evaluation, plus day, remount, view and new
  movement-condition stress tests. Compare against simple baselines.
- Report error distributions, sensor-reference uncertainty and failure cases.
- Preserve user-controlled deletion/withdrawal, including derived caches.

## Capture configuration optimization (proposed, not yet app defaults)

1080p at 60fps is a useful default to benchmark for fast board and foot motion.
Do not mandate 4K; test when higher resolution materially improves tracking.
Keep the entire body, board and roller in view; stabilize the camera and
minimize motion blur. Save the camera intrinsics and lens corrections when
available. Use multiple calibrated views in research data collection.

The current 120-second guided protocol should remain the reproducible skill
baseline. A separate longer endurance protocol is needed for meaningful
fatigue-degradation analysis, with safe rest and termination options.

A detailed scan is optional for individual geometry. It does not measure body
composition, deep tissue deformation, plantar pressure or live muscle activity.

## Prioritized next changes

P0: Real physical synchronization / authorization verification and a separate
    qualified teacher-label receipt. Do not rely on receipt presence alone.
P1: Target-specific time-series format with masks, units, frames and electrode
    or foot-insole reference metadata.
P2: Small iPhone research-capture readiness panel that does not burden
    everyday users or silently grant research permission.
P3: Pilot video-to-bilateral-load benchmark, followed by measured EMG with
    a robust held-out-person evaluation and personal-adaptation study.
P4: Anatomical replay showing observed, modeled and supervised estimates
    separately, with error/uncertainty overlays.

Software test passing is not device qualification or proof of measured
musculoskeletal prediction accuracy.
