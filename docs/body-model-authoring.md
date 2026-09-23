# Body-model authoring and registration repeatability

This is the B5D path for turning a real body scan plus measured landmarks into a
versioned MotionOS body profile, then checking whether Vision-to-body
registration is repeatable across a camera calibration session.

The two operations answer different questions:

- **authoring** asks whether the personalized geometry is explicit, reproducible,
  and bound to immutable source bytes;
- **repeatability** asks whether the same declared geometry can be registered
  consistently across many camera poses.

Neither operation proves anatomical ground-truth accuracy.

## 1. Preserve the source scan

Keep the original mesh or point cloud unchanged. The authoring command hashes
those exact bytes and writes that SHA-256 into the body profile.

Do not edit the source mesh in place after freezing the profile. A materially
changed scan is a new evidence version.

## 2. Create an authoring spec

Copy:

```text
examples/body-model-authoring.example.json
```

The spec contains:

- model ID and height;
- explicit body-frame convention;
- metric landmark coordinates;
- the subset of landmarks allowed for rigid/similarity registration;
- segment definitions as landmark pairs;
- optional explicit segment lengths;
- optional joint limits;
- source scan path and type;
- authoring metadata.

Left and right landmarks remain independent. Missing contralateral geometry is
not mirrored automatically.

## 3. Build the profile

```bash
motionos build-body-model \
  body-model-authoring.json \
  profiles/body-model.json

motionos validate-body-model \
  profiles/body-model.json \
  --source-artifact profiles/body-scan-source.glb
```

The builder:

- hashes the original source artifact;
- computes segment lengths from declared landmark pairs;
- rejects missing landmarks;
- rejects zero-length/non-finite geometry;
- rejects ambiguous segment names that are both computed and explicit;
- writes `motionos.body-model.v2`;
- reloads and validates the output;
- verifies the source-artifact hash after writing.

The profile metadata records the authoring-spec SHA-256 for reproducibility.

## 4. Collect multiple calibration poses

Use the camera evidence path to record a MotionOS camera session containing
`/camera/pose3d`.

Useful repeatability coverage includes:

- quiet neutral stance;
- small left/right torso rotations;
- modest arm-position changes while torso registration landmarks remain visible;
- several distances from the camera within the intended calibration setup.

Do not select only frames that register well. The evaluator accounts for every
pose event in the session.

## 5. Evaluate registration repeatability

```bash
motionos evaluate-body-registration \
  profiles/body-model.json \
  data/camera/<camera-session> \
  data/body-registration/report.json
```

The report contains:

- body profile ID/hash and source scan hash;
- exact camera-session bundle hash and source-file hashes;
- total/successful/failed pose-frame counts;
- explicit failure reasons;
- per-frame residual RMS/max;
- per-frame fitted scale, rotation, and translation;
- residual median/p95/max;
- scale median/min/max/range/coefficient of variation;
- successful time span.

A corrupted or underconstrained pose is retained as a failed frame. It is never
silently discarded from the denominator.

## Interpreting the output

Residual stability and scale stability are useful diagnostics, but this tranche
does not hard-code a universal pass threshold. Thresholds should be frozen only
after collecting representative real calibration evidence and deciding what
downstream use requires.

A low residual can still be systematically wrong if scan landmarks or Vision
landmarks are biased. Repeatability is not accuracy.

## First real scan closure

For a personalized first ride:

1. preserve the original scan bytes;
2. author the v2 profile from measured landmarks;
3. verify the source hash;
4. collect multiple camera calibration poses;
5. run the repeatability report;
6. review failures, residuals, and scale stability;
7. only then freeze the profile version used by the calibration run.
