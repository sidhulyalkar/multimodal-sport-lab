# M1-A1A Calibrated Multi-Camera World Geometry

M1-A1A adds a metric visual geometry layer that is independent of Apple's
root-relative Vision 3D pose.

The central rule is:

> A coordinate is not a MotionOS world coordinate merely because it has three
> numbers. World-frame claims require a validated calibration chain.

That chain is:

```text
physical calibration board
        |
        v
declared metric world frame
        |
        v
per-camera intrinsics + distortion + rigid world extrinsic
        |
        v
capture-time mount verification
        |
        v
exact camera session + exact clock map
        |
        v
qualified multi-camera rig
        |
        v
frozen 2D correspondences
        |
        v
triangulation + reprojection diagnostics
```

## 1. Calibration board

Schema:

```text
motionos.calibration-board.v1
```

The first supported board contract is ChArUco.

It records:

- physical square count;
- square size in meters;
- marker size in meters;
- dictionary;
- optional hash of the printable/source board artifact.

The board JSON itself is hashed and is referenced by every world-frame and
camera-calibration artifact.

Changing board dimensions creates a different geometry authority.

## 2. World frame

Schema:

```text
motionos.world-frame.v1
```

A world frame declares:

- a stable `frame_id`;
- units, currently meters;
- textual +X/+Y/+Z semantics;
- origin definition;
- normalized gravity direction;
- exact calibration-board artifact SHA-256.

Example semantics for the first longboard rig might be:

```text
origin = center of calibration-board bottom edge
+X = rider right
+Y = up
+Z = forward along calibration lane
```

The exact convention should be physically marked and frozen before capture.

## 3. Per-camera calibration

Schema:

```text
motionos.camera-calibration.v1
```

Each calibration stores:

- exact camera unique ID;
- host/device identity;
- camera device type / lens class;
- camera position;
- pixel format;
- image dimensions;
- canonical camera axes:

```text
+X right, +Y down, +Z forward
```

- 3x3 intrinsics;
- explicit distortion model and coefficients;
- rigid 4x4 `world_from_camera`;
- exact world-frame and calibration-board hashes;
- calibration source-artifact hashes by role;
- source timestamp semantics;
- calibration software + version;
- reprojection RMS/max/count;
- predeclared reprojection acceptance thresholds;
- `frozen_before_rig_capture=true`.

`world_from_camera` maps metric camera-frame coordinates into the declared
metric world frame.

### Supported persisted distortion models

The artifact contract can preserve:

```text
none
brown_conrady_5
opencv_rational_8
fisheye_4
```

The current triangulation implementation supports `none`,
`brown_conrady_5`, and `opencv_rational_8`.

A fisheye calibration may be preserved, but triangulation fails explicitly
until a tested fisheye projection path exists.

No silent pinhole substitution is allowed.

## 4. Camera calibration receipt

Run:

```bash
motionos validate-camera-calibration   camera-a-calibration.json   --receipt camera-a-calibration-receipt.json
```

Schema:

```text
motionos.camera-calibration-receipt.v1
```

`passed=true` requires the observed reprojection RMS and maximum to be within
the thresholds frozen inside the calibration artifact.

The receipt validates an artifact contract and its declared residuals. It does
not prove the tripod remained fixed after calibration.

## 5. Capture-time mount verification

Schema:

```text
motionos.camera-mount-verification.v1
```

Before or during the actual calibration run, re-observe the fixed target and
derive an observed `world_from_camera`.

The verification binds:

- camera ID;
- exact camera session ID;
- exact frozen calibration hash;
- observed camera transform;
- exact mount-check image/video evidence hashes.

MotionOS computes:

- translation drift from the frozen camera center;
- rotation drift from the frozen camera orientation.

The rig spec declares maximum drift thresholds before review.

This is the moved-tripod detector.

## 6. Per-camera time remains independent

Every camera preserves its native PTS clock.

A multi-camera rig does not magically make one camera the time authority.

Each camera entry must bind an exact:

```text
motionos.clock-uncertainty.v1
```

artifact whose:

- reference session ID + bundle hash;
- camera target session ID + bundle hash

match the actual rig inputs.

This lets geometry and timing uncertainty remain separate, inspectable
authorities.

## 7. Fixed multi-camera rig

Build:

```bash
motionos build-camera-rig   camera-rig-spec.json   camera-rig-receipt.json
```

Schema:

```text
motionos.camera-rig-receipt.v1
```

The initial rig requires at least two cameras.

All cameras must share the exact same:

- world-frame artifact hash;
- calibration-board artifact hash.

The spec freezes thresholds for:

- minimum pairwise baseline;
- minimum angle between optical axes;
- maximum mount translation drift;
- maximum mount rotation drift.

A rig passes only when:

```text
camera calibration quality
AND viewpoint separation
AND mount stability
```

all pass.

A poor calibration, bumped tripod, stale clock map, changed source session, or
mixed world frame therefore prevents downstream world-coordinate claims.

## 8. Frozen multi-view correspondences

Schema:

```text
motionos.multiview-correspondences.v1
```

A correspondence artifact binds the exact camera-rig receipt SHA and contains
pixel observations keyed by camera ID.

It must contain:

```json
"frozen_before_geometry_review": true
```

so points are not nudged after inspecting the reconstructed 3D answer.

Each point also carries a reference-timeline timestamp.

## 9. Triangulation

Run:

```bash
motionos triangulate-multiview   camera-rig-receipt.json   multiview-correspondences.json   multiview-geometry-report.json   --measurements-output geometry-measurements.json
```

Triangulation requires a passing camera-rig receipt.

For each pixel observation MotionOS:

1. removes intrinsics;
2. numerically undistorts supported lens models;
3. creates a camera-frame ray;
4. rotates that ray into the metric world frame;
5. solves the least-squares closest point across all camera rays;
6. reprojects the recovered point through each camera model.

The output reports:

- world position in meters;
- per-camera reprojection residual in pixels;
- mean reprojection residual;
- RMS distance from the triangulated point to the observation rays.

## 10. Residual benchmark bridge

With `--measurements-output`, the geometry pipeline also writes:

```text
motionos.geometry-measurements.v1
```

containing:

```text
camera_reprojection_residual_px
cross_view_triangulation_disagreement_m
```

This file feeds directly into the M1-A2 residual benchmark rather than creating
a parallel metric vocabulary.

## 11. Failure modes are evidence

The code intentionally fails or refuses the world claim when:

- a board/world/calibration file hash changes;
- camera unique ID does not match the camera session;
- two cameras reference different world frames;
- two cameras reference different calibration boards;
- a clock map references the wrong camera session;
- mount verification references a stale calibration;
- mount translation/rotation drift exceeds frozen thresholds;
- baseline/view-angle separation is inadequate;
- correspondence file references a different rig receipt;
- correspondence editing was not frozen before geometry review;
- a pixel lies outside calibrated image bounds;
- triangulation geometry is singular;
- a reconstructed point lies behind a camera;
- an unsupported distortion model is requested for triangulation.

## 12. What A1A does not yet provide

A1A does **not** yet implement:

- rigid fiducial pose on the longboard;
- camera-derived equipment pose;
- equipment marker-to-pod mount validation;
- frozen static-pose body registration;
- moving-pose drift against that frozen body transform.

Those are M1-A1B.

## Claim boundary

Calibrated multi-view video is a stronger geometric reference than root-relative
single-camera pose, but it is not automatic laboratory ground truth.

Reprojection agreement and ray agreement measure consistency with the declared
calibration. Absolute accuracy still depends on board geometry, calibration
quality, camera stability, correspondence quality, and independent validation.
