# M2.2: Source-bound bilateral pressure reference series

Status: **private, derived research evidence**, not a calibrated physiological
ground-truth dataset or trained vision model.

This step depends on [M2.1 teacher source qualification](teacher-source-qualification-v1.md).
It deliberately consumes the original MotionOS OpenGo M0 recordings instead of
copying or rewriting their raw samples.

## What it computes

For each timestamp shared by OpenGo left/right foot pressure streams:

    left_load_fraction = left_normal_force_n /
        (left_normal_force_n + right_normal_force_n)

It only produces a number for nonnegative, finite force readings with positive
total force and both feet available. Otherwise it emits a row with a **null
value**, valid=false and an explicit reason such as missing_side,
missing_force, negative_force, nonfinite_force or zero_total_force. Samples
within the source-qualified video window retain native time, canonical
reference time and mapped source-video presentation timestamp.

Missing samples are **never interpolated**, and gaps longer than 500 ms are
reported explicitly. Original insole side labels must remain anatomically
correct: left/right are not interchangeable camera-left/camera-right.

## Source and time invariants

- Re-verify the complete M2.1 source qualification report and original hashes.
- The referenced measured candidate must bind left_load_fraction and
  bilateral_pressure to a real OpenGo source-native pressure stream.
- Both source streams must be in the exact same original MotionOS M0 session,
  with pressure units canonicalized to kPa and an explicit
  OpenGo export-relative timestamp basis.
- Recompute the clock sync against original reference and insole sessions;
  recalculate camera alignment against the original video.
- Reject a second arbitrary BLE clock or camera reconstruction used as a
  substitute for measured pressure. Independently clocked pressure sources
  will require separate verified synchronization receipts in a later version.
- Preserve the original normal-force values (N), total force (N), dimensionless
  load fraction, invalid-value masks, gaps, camera timing and all source digests.
- Label provenance explicitly as "derived from measured normal force".
  This is not an observed quantity from video, nor full 3D GRF.
- Prevent accidental output overwrite of original sensor or video sources.

## Input

A private spec, e.g. private/bilateral-spec.json, containing:

    {
      "schema_version": "motionos.bilateral-load-series-spec.v1",
      "source_qualification": "source-bound-report.json",
      "samples": [
        {
          "sample_id": "ride-001",
          "calibration_receipt": "calibration/insole-reference.json"
        }
      ]
    }

calibration_receipt is optional and SHA-256 bound when provided. It is NOT
silently approved as physical calibration by this command; output always
reports calibration_verified=false.

Commands:

    motionos build-bilateral-load-series \
      private/bilateral-spec.json private/series.json
    motionos verify-bilateral-load-series private/series.json

The output includes per-timepoint valid/invalid labels and a numeric quality
summary. It has privacy_classification="derived_restricted" and
training_ready=false even when every software check passes.

## Deliberate model-research boundaries

A stable video-only model must demonstrate generalization to unseen
participants, sessions, remounts, camera views, board styles and lighting,
not simply reproduce video-adjacent sensor samples. Use the previously
implemented participant/day/remount grouped splits.

The output is **not** reliable physiological ground truth until a separate
human-reviewed gate verifies consent, withdrawal status, source-native
pressure calibration, load zeroing, insole orientation and anatomical sides,
hardware accuracy, units, real clock alignment quality, and task-specific
coverage requirements. A video-derived model must not be trained and claimed
validated solely because this output exists.

For EMG, do not reuse force fractions as "muscle activation". A future module
needs electrode/site metadata, sampling rate, reference method, filtering,
normalization, artifacts and signal quality, before a temporal activation
envelope can be evaluated fairly.

## Pilot acceptance

Synthetic regression tests verify mapping, 0.4 load-fraction reconstruction,
missing-right masks, zero-load masks, negative-force masks, tamper detection,
and raw-overwrite rejection. They **do not** qualify physical insole equipment.

Next layer: dedicated OpenGo P2 physical calibration receipt verification,
participant authorization, subject-held-out train/eval set builder, and an
opt-in Research Capture view without disrupting everyday iPhone recording.
