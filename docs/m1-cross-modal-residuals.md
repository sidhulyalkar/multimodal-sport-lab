# M1 Cross-Modal Residual Benchmark

The residual benchmark exists to answer a deliberately narrow question:

> When two MotionOS evidence streams are supposed to describe the same event or
> motion, how much do they disagree?

It does **not** turn one sensor into ground truth merely because it is labeled
"reference".

The report schema is:

```text
motionos.cross-modal-residual-report.v1
```

Build a report with:

```bash
motionos build-cross-modal-residual-report \
  cross-modal-residual-spec.json \
  cross-modal-residual-report.json
```

## Provenance boundary

Every referenced session must include its exact MotionOS session bundle SHA-256.

Every clock-uncertainty, visual-event, strata, registration, or geometry artifact
must include its exact file SHA-256 in the spec.

The report records the spec hash and the hashes of all consumed evidence.

A path with the right filename and changed bytes fails closed.

## IMU versus Vision segment rotation

MotionOS can compare a camera-derived limb/segment axis with an IMU mounted on
that segment without pretending Vision observes every rotational degree of
freedom.

For consecutive Vision 3D poses:

1. choose a declared proximal and distal joint;
2. form the segment unit vector;
3. compute the axis-angle change between consecutive unit vectors;
4. divide by pose interval to obtain a visual angular-velocity vector;
5. rotate IMU gyro into the declared Vision pose frame;
6. remove the gyro component parallel to the segment axis;
7. compare the remaining perpendicular gyro vector with the visual estimate.

The projection in step 6 is essential.

A single segment axis cannot observe twist about itself. Comparing the full gyro
vector against Vision would therefore create a fake error term for an
unobservable degree of freedom.

The spec must provide a proper 3x3 `imu_to_pose_rotation`. MotionOS validates
that it is approximately orthonormal with determinant +1.

The transform must also include a non-empty `rotation_provenance` and
`rotation_frozen_before_residual_review=true`. This prevents optimizing the
mount transform after inspecting the residuals.

The report includes:
- residual vector in rad/s;
- residual norm;
- pairing time delta;
- clock predictive uncertainty;
- visual pose interval;
- skipped intervals caused by large pose gaps;
- robustness-stratified residual distributions.

This is a consistency metric, not a calibrated angular-velocity error unless
one modality has independent qualification.

## Pressure versus reviewed visual contact

Current MotionOS camera evidence stores root-relative Vision 3D joints. That is
not enough to infer board/ground contact robustly.

Therefore the benchmark does **not** infer visual contact from pose geometry.

Instead, visual contact events are explicit reviewed evidence:

```json
{
  "schema_version": "motionos.visual-contact-events.v1",
  "review_protocol": {
    "pressure_trace_hidden": true,
    "events_frozen_before_comparison": true
  },
  "events": [
    {
      "time_ns": 1000000000,
      "side": "left",
      "event": "contact_onset",
      "uncertainty_ns": 5000000
    }
  ]
}
```

Pressure contact uses a predeclared `normal_force_n` threshold, and the
comparison spec requires `threshold_frozen_before_residual_review=true`.

Reviewed visual events require the pressure trace to have been hidden during
annotation and the event list to have been frozen before comparison. This
prevents annotators from nudging visual contact times toward pressure events.

The pressure-device event is mapped into camera/reference time using the
`motionos.clock-uncertainty.v1` model.

For each matched event, the report preserves:

```text
residual_ms = pressure_mapped_time - visual_time
combined_timing_std_ms
absolute_residual_over_combined_std
```

A positive residual means pressure crossed the threshold after the reviewed
visual event.

The ratio to combined timing uncertainty is reported as a diagnostic only. It
is not converted into a significance label or pass/fail claim.

## Geometry

### Personalized body registration

A hash-bound `motionos.body-registration-report.v1` may be included directly.

The residual benchmark preserves successful/failed registration counts and
stratifies per-frame registration RMS residuals.

### Reprojection and multi-view triangulation

These require evidence that the current single-camera Vision stream does not
always contain.

When independently computed geometry evidence exists, provide:

```json
{
  "schema_version": "motionos.geometry-measurements.v1",
  "measurements": [
    {
      "time_ns": 1000000000,
      "metric": "camera_reprojection_residual_px",
      "value": 2.1,
      "unit": "px"
    },
    {
      "time_ns": 1000000000,
      "metric": "cross_view_triangulation_disagreement_m",
      "value": 0.012,
      "unit": "m"
    }
  ]
}
```

The benchmark does not invent these quantities if the underlying 2D/3D or
multi-view evidence is absent.

## Robustness strata

Use a hash-bound `motionos.robustness-strata.v1` artifact.

Supported labels are:

```text
motion_speed
occlusion
pose_confidence
distance_framing
sensor_gap
day_id
remount_id
camera_view
```

Example:

```json
{
  "schema_version": "motionos.robustness-strata.v1",
  "frozen_before_residual_review": true,
  "intervals": [
    {
      "start_ns": 0,
      "end_ns": 10000000000,
      "labels": {
        "motion_speed": "slow",
        "occlusion": "clear",
        "pose_confidence": "high",
        "distance_framing": "near",
        "sensor_gap": "none",
        "day_id": "day-1",
        "remount_id": "mount-1",
        "camera_view": "side"
      }
    }
  ]
}
```

The strata artifact must be frozen before residual review. Intervals may overlap
only when their labels do not conflict at a timestamp.

Unlabeled samples are retained as `__unlabeled__` rather than silently
discarded.

## No aggregate score

The report intentionally contains no scalar "quality score".

Each modality pair reports its own distribution:
- count;
- mean;
- median;
- RMS;
- p95 absolute residual;
- max absolute residual.

Those distributions are repeated by robustness stratum.

Collapsing timing, angular velocity, pressure events, reprojection, and
registration into one number would hide the failure mode the benchmark is
supposed to expose.

## Current unsupported claims

The current camera contract does not justify:
- automatic equipment visual angular velocity unless equipment pose evidence is
  separately added;
- automatic visual foot/board contact from root-relative pose alone;
- camera reprojection error without independently preserved 2D correspondence;
- cross-view triangulation disagreement without multi-view geometry evidence.

The report makes those missing authorities visible rather than filling them with
assumptions.

## Claim boundary

Residual agreement measures consistency between evidence streams. It does not
prove either stream is physically accurate unless one stream has an independent
qualified reference.
