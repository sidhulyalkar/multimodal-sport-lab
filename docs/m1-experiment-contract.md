# M1-A0 Observability, Experiment, and Split Contract

M1-A0 exists to prevent future models from looking convincing for the wrong
reason.

It adds three independent contracts:

1. observability registry — what may be estimated at all;
2. experiment manifest — exactly which evidence/model artifacts produced a run;
3. grouped split artifact — exactly which acquisition groups belong to
   train/validation/test.

These do not replace M0 session/calibration manifests.

## 1. Observability registry

Example:

```bash
motionos validate-observability   examples/longboard-observability.example.json
```

A variable declares:

- units;
- coordinate frame;
- observability state;
- teacher eligibility;
- direct evidence modalities;
- indirect evidence modalities;
- required transforms;
- reference sources;
- known ambiguities;
- explicit non-claims.

Supported observability states:

```text
observable
conditional
unidentifiable
```

An `unidentifiable` variable cannot be `teacher_eligible=true`.

This prevents downstream training code from quietly treating an unsupported
quantity such as full 3D GRF or full-body joint torque as a supervised target.

The first longboard registry is:

```text
examples/longboard-observability.example.json
```

It is intentionally conservative.

## 2. Experiment manifest

The experiment manifest binds an M1 analysis to:

- exact repository commit;
- exact observability registry hash;
- protocol version;
- pseudonymous subject;
- acquisition day;
- run identity;
- remount identity;
- optional camera view and intensity;
- exact MotionOS session hashes;
- exact supporting artifact hashes;
- model name/version;
- model weights SHA-256 when weights are external artifacts;
- requested teacher targets.

Build one with:

```bash
motionos build-experiment-manifest   experiment-spec.json   artifacts/experiment.json
```

Start from:

```text
examples/m1-experiment-spec.example.json
```

A source is either:

```text
source_type=session
```

for a canonical MotionOS session bundle, or:

```text
source_type=artifact
```

for a single immutable file.

Session sources use the MotionOS session evidence digest rather than hashing only
one file inside the bundle.

A target must exist in the referenced observability registry and must be
teacher-eligible.

## 3. Leakage-safe grouped splits

The split input is a JSON object with a `samples` list, or a raw JSON list.

Each sample requires:

```text
sample_id
```

plus the grouping fields selected for the split.

Example run-held-out split:

```bash
motionos build-grouped-split   examples/m1-sample-index.example.json   artifacts/split-by-run.json   --group-by run_id   --seed longboard-m1-v1
```

Example day/remount split:

```bash
motionos build-grouped-split   data/m1/sample-index.json   artifacts/split-by-day-remount.json   --group-by day_id,remount_id   --seed longboard-m1-v1
```

The stable hash partition is computed from the frozen seed plus the complete
group key.

All samples sharing that group key are indivisible.

For a primary benchmark, at least one acquisition-level field is required:

- repetition_id;
- run_id;
- day_id;
- remount_id;
- camera_view;
- intensity;
- subject_id;
- sport.

Window-only grouping is rejected for `purpose=primary`.

The split artifact records:

- source sample-index SHA-256;
- group fields;
- frozen seed;
- fractions;
- sample assignments;
- group assignments;
- leakage check.

Changing the source index changes the split provenance even when the command
line is otherwise identical.

## Recommended benchmark ladder

Do not produce one canonical split.

Freeze a family of increasingly difficult evaluations:

```text
held-out repetition
held-out run
held-out day
held-out remount
held-out view
held-out intensity
held-out subject
held-out sport
```

A model result must name the exact split artifact used.

Random adjacent-window splits may be used for development/debugging only and
must use `purpose=development`.

## Public-data preflight

MotionOS includes a local adapter for an already authorized TotalCapture
extraction:

```bash
motionos index-totalcapture   /path/to/TotalCapture   artifacts/totalcapture-index.json
```

The adapter does not download, copy, or redistribute dataset bytes.

It recognizes the common subject/sequence form:

```text
TotalCapture/
  s1/
    acting1/
      gt_skel_gbl_pos.txt
      gt_skel_gbl_ori.txt
      *_Xsens*.sensors
      *cam*.mp4
```

A sequence is indexed only when Vicon global-position evidence and an Xsens
`.sensors` file coexist.

Use dataset access and licenses from the dataset owners. Repository fixtures
exercise only the adapter contract; they are not TotalCapture data.

## What this tranche deliberately does not do

M1-A0 does not:

- create an offline fused teacher;
- train a neural network;
- claim public-dataset benchmark performance;
- qualify MotionOS hardware;
- infer missing biomechanical quantities.

Those require later evidence.

## Next dependency

After real M0 physical evidence exists, use these manifests and splits with:

- M1-A1 calibrated world/multi-camera geometry;
- M1-A2 deterministic cross-modal residuals and timing uncertainty.

Only after those references are characterized should the learned offline teacher
be treated as a primary target source.
